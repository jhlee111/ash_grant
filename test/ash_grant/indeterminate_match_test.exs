defmodule AshGrant.IndeterminateMatchTest do
  @moduledoc """
  Covers issue #126's second layer: without an `action_type`, a type wildcard silently
  fails to match, so the returned answer may be fabricated rather than real.

  `async: false` — the mode is read from the application environment.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshGrant.Evaluator
  alias AshGrant.IndeterminateMatch
  alias AshGrant.IndeterminateMatch.IndeterminateMatchError

  setup do
    original = Application.fetch_env(:ash_grant, :indeterminate_type_wildcard)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ash_grant, :indeterminate_type_wildcard, value)
        :error -> Application.delete_env(:ash_grant, :indeterminate_type_wildcard)
      end
    end)

    :ok
  end

  defp set_mode(mode) do
    Application.put_env(:ash_grant, :indeterminate_type_wildcard, mode)
    :ok
  end

  defp count_signals(log) do
    log |> String.split("indeterminate authorization result") |> length() |> Kernel.-(1)
  end

  describe "mode/0" do
    test "defaults to :warn when unconfigured" do
      Application.delete_env(:ash_grant, :indeterminate_type_wildcard)
      assert IndeterminateMatch.mode() == :warn
    end

    test "reads the configured mode" do
      set_mode(:strict)
      assert IndeterminateMatch.mode() == :strict
    end
  end

  describe ":warn — signals only when the answer could be wrong" do
    setup do: set_mode(:warn)

    test "an allow wildcard was skipped and nothing else matched" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:*:read*:always"], "m", "read") == false
        end)

      assert log =~ "indeterminate authorization result for m:read"
      assert log =~ "m:*:read*:always"
      assert log =~ "a grant that may allow it was skipped"
    end

    test "the @read spelling is flagged identically — renaming does not fix this" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:*:@read:always"], "m", "read") == false
        end)

      assert log =~ "indeterminate authorization result"
      assert log =~ "m:*:@read:always"
    end

    test "a deny wildcard was skipped and access was granted (fail-open direction)" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:*:read:always", "!m:*:read*:sensitive"], "m", "read") ==
                   true
        end)

      assert log =~ "a deny rule that may forbid it was skipped"
      assert log =~ "!m:*:read*:sensitive"
    end

    test "silent for a defensive wildcard + literal pair — the answer is right either way" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:*:read*:always", "m:*:read:always"], "m", "read") ==
                   true
        end)

      refute log =~ "indeterminate"
    end

    test "silent for a legitimate false with no wildcards involved" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:*:write:always"], "m", "read") == false
        end)

      refute log =~ "indeterminate"
    end

    test "silent when an action_type is supplied — everything was evaluable" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:*:read*:always"], "m", "read", :read) == true
        end)

      refute log =~ "indeterminate"
    end

    test "silent when the skipped wildcard belongs to another resource" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["other:*:read*:always"], "m", "read") == false
        end)

      refute log =~ "indeterminate"
    end

    test "silent for a type wildcard on an instance permission (not the RBAC path)" do
      # Dead outright, and reported by Permission.diagnostics/1 instead.
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:m_abc123:read*:"], "m", "read") == false
        end)

      refute log =~ "indeterminate"
    end

    test "a resource wildcard grant is still relevant" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["*:*:read*:always"], "m", "read") == false
        end)

      assert log =~ "indeterminate"
    end

    test "never changes the returned value" do
      capture_log(fn ->
        assert Evaluator.has_access?(["m:*:read*:always"], "m", "read") == false
        assert Evaluator.has_access?(["m:*:read:always", "!m:*:read*:x"], "m", "read") == true
      end)
    end

    test "deduplicates repeated identical checks within one process" do
      log =
        capture_log(fn ->
          Enum.each(1..5, fn _ ->
            Evaluator.has_access?(["m:*:read*:always"], "m", "read")
          end)
        end)

      assert count_signals(log) == 1
    end

    test "distinct questions are reported separately" do
      log =
        capture_log(fn ->
          Evaluator.has_access?(["m:*:read*:always"], "m", "read")
          Evaluator.has_access?(["m:*:read*:always"], "m", "list")
        end)

      assert count_signals(log) == 2
    end
  end

  describe ":strict — the category error surfaces immediately" do
    setup do: set_mode(:strict)

    test "raises when the answer is indeterminate" do
      assert_raise IndeterminateMatchError,
                   ~r/indeterminate authorization result for m:read/,
                   fn ->
                     Evaluator.has_access?(["m:*:read*:always"], "m", "read")
                   end
    end

    test "raises on the fail-open deny direction too" do
      assert_raise IndeterminateMatchError, ~r/deny rule that may forbid it/, fn ->
        Evaluator.has_access?(["m:*:read:always", "!m:*:read*:sensitive"], "m", "read")
      end
    end

    test "does not raise where the answer is sound — :strict is safe to adopt" do
      assert Evaluator.has_access?(["m:*:read*:always", "m:*:read:always"], "m", "read") == true
      assert Evaluator.has_access?(["m:*:read*:always"], "m", "read", :read) == true
      assert Evaluator.has_access?(["m:*:write:always"], "m", "read") == false
      assert Evaluator.has_access?(["other:*:read*:always"], "m", "read") == false
    end
  end

  describe ":off — no detection, no signal" do
    setup do: set_mode(:off)

    test "stays silent and returns the unchanged result" do
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(["m:*:read*:always"], "m", "read") == false
        end)

      refute log =~ "indeterminate"
    end
  end

  describe "forced-recompute soundness — no false positives" do
    setup do: set_mode(:strict)

    test "silent when a skipped wildcard contributes nothing (scope-less / group-less)" do
      # With :read the wildcard would match, but its empty scope / absent field_group
      # contributes nothing, so the result is identical either way — determinate.
      assert Evaluator.get_all_scopes(["blog:*:@read:"], "blog", "read") == []
      assert Evaluator.get_scope(["blog:*:@read:"], "blog", "read") == nil

      assert Evaluator.get_all_field_groups(
               ["sensitiverecord:*:@read:always"],
               "sensitiverecord",
               "read"
             ) == []
    end

    test "silent when a concrete deny already fixed the result" do
      # The concrete deny wins regardless of how the @read wildcard would resolve.
      assert Evaluator.has_access?(["!m:*:read:x", "m:*:@read:always"], "m", "read") == false
      assert Evaluator.get_scope(["!m:*:read:x", "m:*:@read:always"], "m", "read") == nil
    end

    test "silent when a field-group wildcard cannot grant the required group" do
      # @read matches the action, but "public" does not grant :sensitive, so
      # field_group_grants excludes it whether or not the type is known.
      grants =
        Evaluator.field_group_grants(
          ["sensitiverecord:*:@read:always:public"],
          AshGrant.Test.SensitiveRecord,
          "read",
          :sensitive
        )

      assert grants == []
    end
  end

  describe "coverage across the guarded entry points" do
    setup do: set_mode(:strict)

    test "get_all_scopes raises when a skipped wildcard would add a scope" do
      assert_raise IndeterminateMatchError, fn ->
        Evaluator.get_all_scopes(["blog:*:@read:own"], "blog", "read")
      end
    end

    test "get_scope raises when a skipped wildcard would supply the first scope" do
      assert_raise IndeterminateMatchError, fn ->
        Evaluator.get_scope(["blog:*:@read:own"], "blog", "read")
      end
    end

    test "get_write_scopes raises when a skipped wildcard would join the union" do
      assert_raise IndeterminateMatchError, fn ->
        Evaluator.get_write_scopes(["blog:*:@read:own"], "blog", "read")
      end
    end

    test "get_field_group raises when a skipped wildcard would supply the group" do
      assert_raise IndeterminateMatchError, fn ->
        Evaluator.get_field_group(
          ["sensitiverecord:*:@read:always:sensitive"],
          "sensitiverecord",
          "read"
        )
      end
    end

    test "get_all_field_groups raises when a skipped grouped wildcard would add a group" do
      assert_raise IndeterminateMatchError, fn ->
        Evaluator.get_all_field_groups(
          ["sensitiverecord:*:@read:always:sensitive"],
          "sensitiverecord",
          "read"
        )
      end
    end

    test "find_matching raises when a skipped wildcard would join the list" do
      assert_raise IndeterminateMatchError, fn ->
        Evaluator.find_matching(["blog:*:@read:always"], "blog", "read")
      end
    end

    test "field_group_grants raises when a skipped wildcard would grant the group" do
      assert_raise IndeterminateMatchError, fn ->
        Evaluator.field_group_grants(
          ["sensitiverecord:*:@read:always:sensitive"],
          AshGrant.Test.SensitiveRecord,
          "read",
          :sensitive
        )
      end
    end

    test "every guarded entry point stays silent once the action type is supplied" do
      assert Evaluator.get_all_scopes(["blog:*:@read:own"], "blog", "read", :read) == ["own"]
      assert Evaluator.get_scope(["blog:*:@read:own"], "blog", "read", :read) == "own"

      assert Evaluator.get_write_scopes(["blog:*:@read:own"], "blog", "read", :read) ==
               {:scopes, ["own"]}

      assert Evaluator.find_matching(["blog:*:@read:always"], "blog", "read", :read) != []
    end
  end

  describe "the two-layer asymmetry (issue #126)" do
    setup do: set_mode(:warn)

    test "can?/4 and has_access?/3 disagree on the same grant; the untyped one now says so" do
      actor = %{permissions: ["document:*:@read:always"]}

      # Takes the resource module, so it resolves the action type and answers correctly.
      assert {:allow, _details} = AshGrant.Introspect.can?(AshGrant.Test.Document, :read, actor)

      # Takes a resource string, so it cannot resolve the type. Same actor, same grant,
      # opposite answer — previously silent, now reported.
      log =
        capture_log(fn ->
          assert Evaluator.has_access?(actor.permissions, "document", "read") == false
        end)

      assert log =~ "indeterminate authorization result for document:read"
      assert log =~ "AshGrant.Introspect.can?/4"
    end
  end
end

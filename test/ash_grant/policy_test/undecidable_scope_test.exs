# The fixtures live outside the ExUnit module: nested there, `use AshGrant.PolicyTest`'s
# `test/2` would collide with the one ExUnit.Case imports.

defmodule AshGrant.PolicyTest.UndecidableScope.FragmentPolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Post)

  actor(:today_reader, %{permissions: ["post:*:read:today"]})
  actor(:mixed_reader, %{permissions: ["post:*:read:today", "post:*:read:published"]})

  test "assert_cannot is not decided by a fragment scope" do
    assert_cannot(:today_reader, :read, %{status: :draft})
  end

  test "assert_can is not decided by a fragment scope" do
    assert_can(:today_reader, :read, %{status: :draft})
  end

  test "another grant's scope still admits the record" do
    assert_can(:mixed_reader, :read, %{status: :published})
  end

  test "an undecidable scope leaves an otherwise rejecting union undecided" do
    assert_cannot(:mixed_reader, :read, %{status: :draft})
  end
end

defmodule AshGrant.PolicyTest.UndecidableScopeTest do
  @moduledoc """
  A policy test evaluates scopes in memory. When a scope's filter cannot be
  evaluated there — a SQL `fragment()`, an `exists()`, anything `Ash.Expr.eval`
  cannot decide — the assertion must fail in BOTH directions (#143). Treating
  it as `true` passed `assert_can` blindly; treating it as `false` would pass
  `assert_cannot` blindly.
  """
  use ExUnit.Case, async: true

  import Ash.Expr

  alias AshGrant.PolicyTest.{Assertions, Runner, YamlParser}
  alias AshGrant.PolicyTest.UndecidableScope.FragmentPolicyTest

  @actor %{id: "u1"}

  defp evaluate(resource, filter, record) do
    Assertions.evaluate_filter_against_record(filter, record, @actor, resource, %{})
  end

  defp scope(resource, name),
    do: AshGrant.Info.resolve_scope_filter(resource, name, %{actor: @actor})

  describe "evaluate_filter_against_record/5" do
    test "a fragment() is undecidable" do
      assert {:indeterminate, reason} =
               evaluate(AshGrant.Test.Post, scope(AshGrant.Test.Post, :today), %{status: :draft})

      assert reason =~ "fragment()"
    end

    test "an exists() is undecidable" do
      filter = scope(AshGrant.Test.BulkItem, :team_member_and_own)

      assert {:indeterminate, reason} =
               evaluate(AshGrant.Test.BulkItem, filter, %{author_id: "u1"})

      assert reason =~ "exists()"
    end

    test "an evaluation error is undecidable, whatever the rest of the filter says" do
      # The old inspect()+regex fallback found `status == :draft` in the text and
      # returned true, ignoring the conjunct it could not evaluate.
      filter = expr(status == :draft and type(title, :integer) == 1)

      assert {:indeterminate, reason} =
               evaluate(AshGrant.Test.Post, filter, %{status: :draft, title: "abc"})

      assert reason =~ "could not be evaluated"
    end

    test "an evaluation that raises is undecidable" do
      assert {:indeterminate, reason} =
               evaluate(AshGrant.Test.Post, expr(count(comments) > 0), %{})

      assert reason =~ "could not be evaluated"
    end

    test "a non-boolean result is undecidable" do
      assert {:indeterminate, reason} =
               evaluate(AshGrant.Test.Post, expr(title), %{title: "abc"})

      assert reason =~ "not a boolean"
    end

    test "a field the record lacks is nil, and nil does not match" do
      # The runtime row would hold NULL there: a decided "no", not "unknown".
      assert evaluate(AshGrant.Test.Post, scope(AshGrant.Test.Post, :own), %{}) == false
    end
  end

  @fragment_yaml """
  resource: AshGrant.Test.Post

  actors:
    today_reader:
      permissions:
        - "post:*:read:today"
    mixed_reader:
      permissions:
        - "post:*:read:today"
        - "post:*:read:published"

  tests:
    - name: "assert_cannot is not decided by a fragment scope"
      assert_cannot:
        actor: today_reader
        action: read
        record:
          status: draft

    - name: "assert_can is not decided by a fragment scope"
      assert_can:
        actor: today_reader
        action: read
        record:
          status: draft

    - name: "another grant's scope still admits the record"
      assert_can:
        actor: mixed_reader
        action: read
        record:
          status: published

    - name: "an undecidable scope leaves an otherwise rejecting union undecided"
      assert_cannot:
        actor: mixed_reader
        action: read
        record:
          status: draft
  """

  @tag :tmp_dir
  test "both runners fail an assertion they cannot decide, in either direction", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "fragment.yaml")
    File.write!(path, @fragment_yaml)
    {:ok, yaml_results} = YamlParser.run_yaml_tests(path)

    for {runner, results} <- [dsl: Runner.run_module(FragmentPolicyTest), yaml: yaml_results] do
      outcomes = Map.new(results, &{&1.test_name, &1})

      assert outcomes["another grant's scope still admits the record"].passed, "#{runner}"

      for name <- [
            "assert_cannot is not decided by a fragment scope",
            "assert_can is not decided by a fragment scope",
            "an undecidable scope leaves an otherwise rejecting union undecided"
          ] do
        result = outcomes[name]
        refute result.passed, "#{runner}: #{name} passed"
        assert result.message =~ "Cannot decide", "#{runner}: #{result.message}"
        assert result.message =~ "scope `today`", "#{runner}: #{result.message}"
        assert result.message =~ "fragment()", "#{runner}: #{result.message}"
      end
    end
  end
end

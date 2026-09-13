defmodule AshGrant.ExplainOrUnionTest do
  @moduledoc """
  `mix ash_grant.explain` must describe the filter the read path actually
  applies. `FilterCheck` ORs every matching allow scope and lets a scope
  resolving to `true` absorb that union (#149); the explainer reported only the
  first matching allow, so it printed a narrower filter than the one in force,
  and which scope it picked depended on the order the resolver returned grants
  in (#151).
  """
  use ExUnit.Case, async: true

  defmodule Doc do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      # Grants come from the test via context, so each arm can control both the
      # set of permissions and the order they arrive in.
      resolver(fn _actor, context -> Map.get(context || %{}, :grants, []) end)

      resource_name("doc")

      scope(:mine, [], expr(owner_id == ^actor(:id)))
      scope(:active, [], expr(status == :active))
      # Deliberately not named always/all/global: the by-name fast path must not
      # be what makes this one work.
      scope(:everything, [], true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:status, :atom, constraints: [one_of: [:active, :archived]])
      attribute(:owner_id, :uuid)
    end

    actions do
      defaults([:read])
    end
  end

  defp explain(grants) do
    AshGrant.explain(Doc, :read, %{id: "u1"}, %{grants: grants})
  end

  defp filter_string(grants) do
    grants |> explain() |> Map.fetch!(:scope_filter) |> inspect()
  end

  describe "two matching allow scopes" do
    test "both are reported, not just the first" do
      filter = filter_string(["doc:*:read:mine", "doc:*:read:active"])

      assert filter =~ "owner_id"
      assert filter =~ "status"
    end

    test "reporting does not depend on the order grants arrive in" do
      forward = filter_string(["doc:*:read:mine", "doc:*:read:active"])
      reverse = filter_string(["doc:*:read:active", "doc:*:read:mine"])

      for filter <- [forward, reverse] do
        assert filter =~ "owner_id"
        assert filter =~ "status"
      end
    end
  end

  describe "a scope resolving to true" do
    test "absorbs the union whatever it is named" do
      result = explain(["doc:*:read:everything", "doc:*:read:mine"])

      assert result.scope_filter == true
    end

    test "absorbs it from either position" do
      result = explain(["doc:*:read:mine", "doc:*:read:everything"])

      assert result.scope_filter == true
    end
  end

  describe "controls" do
    test "a single scope is reported unchanged" do
      filter = filter_string(["doc:*:read:mine"])

      assert filter =~ "owner_id"
      refute filter =~ "status"
    end

    test "an undeclared scope does not widen what is reported" do
      # `doc:*:read` is not a scope-less grant — it parses as scope "read",
      # which the resource never declares, so it resolves to `false` and the
      # union is unchanged. Reported the same way FilterCheck combines it.
      filter = filter_string(["doc:*:read", "doc:*:read:mine"])

      assert filter =~ "owner_id"
      refute filter =~ "status"
    end

    test "a deny still reports no filter" do
      result = explain(["doc:*:read:mine", "!doc:*:read:mine"])

      assert result.decision == :deny
      assert result.scope_filter == nil
    end

    test "no matching grant reports no filter" do
      result = explain(["doc:*:update:mine"])

      assert result.decision == :deny
      assert result.scope_filter == nil
    end
  end
end

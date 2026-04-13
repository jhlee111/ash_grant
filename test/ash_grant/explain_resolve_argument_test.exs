defmodule AshGrant.ExplainResolveArgumentTest do
  @moduledoc """
  Tests that `AshGrant.Explainer` surfaces `resolve_argument` declarations so
  users can see — from a single `explain/4` output — how `^arg(...)` values in
  scope expressions are populated at runtime.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.Auth.RefundDsl
  alias AshGrant.Test.BulkItem

  describe "Explainer populates :resolve_arguments" do
    test "resource with resolve_argument lists the declaration annotated with scopes" do
      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["refund_dsl:*:update:at_own_unit"],
        own_org_unit_ids: [Ash.UUID.generate()]
      }

      explanation = AshGrant.Explainer.explain(RefundDsl, :update, actor)

      assert [entry] = explanation.resolve_arguments
      assert entry.name == :center_id
      assert entry.from_path == [:order, :center_id]
      assert entry.scopes_needing == [:at_own_unit]
    end

    test "resource without any resolve_argument returns an empty list" do
      explanation = AshGrant.Explainer.explain(BulkItem, :update, nil)
      assert explanation.resolve_arguments == []
    end

    test "entry is included regardless of whether the actor actually uses it" do
      # The Explanation is a *structural* description of how the resource is
      # wired, so `resolve_arguments` shouldn't depend on which permissions the
      # actor happens to hold. An operator debugging a misconfiguration should
      # be able to see the declaration even when no current actor references it.
      actor = %{id: Ash.UUID.generate(), permissions: [], own_org_unit_ids: []}

      explanation = AshGrant.Explainer.explain(RefundDsl, :update, actor)

      assert [entry] = explanation.resolve_arguments
      assert entry.name == :center_id
    end
  end

  describe "Explanation.to_string renders Argument Resolution section" do
    test "section appears when resolve_arguments is non-empty" do
      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["refund_dsl:*:update:at_own_unit"],
        own_org_unit_ids: [Ash.UUID.generate()]
      }

      output =
        RefundDsl
        |> AshGrant.Explainer.explain(:update, actor)
        |> AshGrant.Explanation.to_string(color: false)

      assert output =~ "Argument Resolution"
      assert output =~ ":center_id"
      assert output =~ ":order"
      assert output =~ ":at_own_unit"
    end

    test "section is omitted when the resource has no resolve_argument declarations" do
      output =
        BulkItem
        |> AshGrant.Explainer.explain(:update, nil)
        |> AshGrant.Explanation.to_string(color: false)

      refute output =~ "Argument Resolution"
    end
  end
end

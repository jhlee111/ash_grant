defmodule AshGrant.ResolveArgumentMultitenancyTest do
  @moduledoc """
  Regression coverage for issue #99:

  `resolve_argument` CREATE path silently failed when any hop in the
  `from_path` pointed to an attribute-multitenant resource, because
  `ResolveArgument.safe_get/2` called `Ash.get!` without forwarding the
  changeset's tenant. The rescued raise left the argument nil, causing the
  argument-based scope to evaluate to `false` and the action to be denied.
  """
  use AshGrant.DataCase, async: false

  alias AshGrant.Test.{TenantOrder, TenantRefund}

  defp actor(perms, extras) do
    Map.merge(%{id: Ash.UUID.generate(), permissions: perms}, extras)
  end

  defp create_order!(tenant_id, center_id) do
    TenantOrder
    |> Ash.Changeset.for_create(:create, %{center_id: center_id}, tenant: tenant_id)
    |> Ash.create!(tenant: tenant_id, authorize?: false)
  end

  describe "resolve_argument on a multitenant target (create path)" do
    test "create succeeds when the argument-based scope matches" do
      tenant = Ash.UUID.generate()
      center = Ash.UUID.generate()
      actor = actor(["tenant_refund:*:create:at_own_unit"], %{own_center_ids: [center]})

      order = create_order!(tenant, center)

      result =
        TenantRefund
        |> Ash.Changeset.for_create(
          :create,
          %{amount: 100, order_id: order.id},
          actor: actor,
          tenant: tenant
        )
        |> Ash.create(actor: actor, tenant: tenant)

      assert {:ok, refund} = result
      assert refund.tenant_id == tenant
    end

    test "create is forbidden when the relational scope does not match" do
      tenant = Ash.UUID.generate()
      order_center = Ash.UUID.generate()
      other_center = Ash.UUID.generate()

      # Actor only owns a center the order does NOT belong to.
      actor = actor(["tenant_refund:*:create:at_own_unit"], %{own_center_ids: [other_center]})

      order = create_order!(tenant, order_center)

      result =
        TenantRefund
        |> Ash.Changeset.for_create(
          :create,
          %{amount: 100, order_id: order.id},
          actor: actor,
          tenant: tenant
        )
        |> Ash.create(actor: actor, tenant: tenant)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "resolve_argument on a multitenant target (update path)" do
    test "update succeeds when the argument-based scope matches" do
      tenant = Ash.UUID.generate()
      center = Ash.UUID.generate()
      actor = actor(["tenant_refund:*:update:at_own_unit"], %{own_center_ids: [center]})

      order = create_order!(tenant, center)

      refund =
        TenantRefund
        |> Ash.Changeset.for_create(
          :create,
          %{amount: 100, order_id: order.id},
          tenant: tenant
        )
        |> Ash.create!(tenant: tenant, authorize?: false)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor, tenant: tenant)
        |> Ash.update(actor: actor, tenant: tenant)

      assert {:ok, updated} = result
      assert updated.amount == 200
    end
  end
end

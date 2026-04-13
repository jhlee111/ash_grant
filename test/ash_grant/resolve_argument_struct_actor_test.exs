defmodule AshGrant.ResolveArgumentStructActorTest do
  @moduledoc """
  Regression coverage for issue #101:

  `AshGrant.Changes.ResolveArgument.needs_resolution?/3` previously only
  inspected `actor.permissions`. Production actors are Ash resource structs
  without a literal `:permissions` field — permissions come from the
  configured `PermissionResolver`. The old implementation silently treated
  such actors as having no permissions, so the change never loaded the
  relationship, `^arg(:name)` stayed nil, and the action was denied.

  The fix routes through the resource's configured resolver, matching
  `AshGrant.Check` / `FilterCheck`.
  """
  use ExUnit.Case, async: false

  alias AshGrant.Test.Auth.{Order, RefundStructActor}

  # Simulates a production actor — an Ash resource / Ecto schema struct that
  # carries domain attributes (role, org unit IDs) but no literal
  # `:permissions` list. Permissions must come from the resolver.
  defmodule Actor do
    @moduledoc false
    defstruct [:id, :role, :own_org_unit_ids]
  end

  setup do
    RefundStructActor
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    Order
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    :ok
  end

  defp create_order!(center_id) do
    Order
    |> Ash.Changeset.for_create(:create, %{center_id: center_id})
    |> Ash.create!(authorize?: false)
  end

  describe "struct actor (no literal :permissions field) drives resolve_argument via the resolver" do
    test "create succeeds when the resolver-returned permission uses the argument-based scope" do
      center = Ash.UUID.generate()
      actor = %Actor{id: Ash.UUID.generate(), role: :center_manager, own_org_unit_ids: [center]}

      order = create_order!(center)

      result =
        RefundStructActor
        |> Ash.Changeset.for_create(
          :create,
          %{author_id: actor.id, order_id: order.id, amount: 50},
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:ok, _} = result
    end

    test "create is forbidden when the resolver-returned permissions do not authorize the action" do
      center = Ash.UUID.generate()
      # `:author` role has an update permission, but no create permission —
      # so create should be forbidden regardless of argument resolution.
      actor = %Actor{id: Ash.UUID.generate(), role: :author, own_org_unit_ids: [center]}

      order = create_order!(center)

      result =
        RefundStructActor
        |> Ash.Changeset.for_create(
          :create,
          %{author_id: actor.id, order_id: order.id, amount: 50},
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "update skips the load when the in-play permissions do not reference the argument" do
      # :author role only has update:by_own_author which doesn't reference
      # ^arg(:center_id), so no DB load for :order should be triggered.
      author_id = Ash.UUID.generate()
      actor = %Actor{id: author_id, role: :author, own_org_unit_ids: []}

      order = create_order!(Ash.UUID.generate())

      refund =
        RefundStructActor
        |> Ash.Changeset.for_create(
          :create,
          %{author_id: author_id, order_id: order.id, amount: 10}
        )
        |> Ash.create!(authorize?: false)

      cs = Ash.Changeset.for_update(refund, :update, %{amount: 20}, actor: actor)

      # Argument was not populated — scope doesn't need it.
      refute match?(%{center_id: v} when not is_nil(v), cs.arguments)

      assert {:ok, _} = Ash.update(cs, actor: actor)
    end
  end
end

defmodule AshGrant.ResolveArgumentDslTest do
  @moduledoc """
  Tests the `resolve_argument` DSL sugar end-to-end: the transformer injects an
  argument declaration + a lazy change on each write action, and the change
  only performs the DB load when a permission-in-play references the argument.

  Mirrors the semantics tested by `AshGrant.ArgumentBasedScopeTest` (which
  uses a hand-rolled change module) so the two implementations can be compared
  1:1.
  """
  use ExUnit.Case, async: false

  alias AshGrant.Test.Auth.{Order, RefundDsl}

  setup do
    RefundDsl |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    Order |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    :ok
  end

  defp actor_with(perms, actor_id, attrs) do
    Map.merge(%{id: actor_id, permissions: perms}, attrs)
  end

  defp create_order!(center_id) do
    Order
    |> Ash.Changeset.for_create(:create, %{center_id: center_id})
    |> Ash.create!(authorize?: false)
  end

  defp create_refund!(author_id, order_id, amount \\ 100) do
    RefundDsl
    |> Ash.Changeset.for_create(:create, %{
      author_id: author_id,
      order_id: order_id,
      amount: amount
    })
    |> Ash.create!(authorize?: false)
  end

  describe ":at_own_unit scope (argument-based, needs order.center_id)" do
    test "update succeeds when order's center_id is in actor's allowed units" do
      actor_id = Ash.UUID.generate()
      center_a = Ash.UUID.generate()
      center_b = Ash.UUID.generate()

      actor =
        actor_with(["refund_dsl:*:update:at_own_unit"], actor_id, %{
          own_org_unit_ids: [center_a, center_b]
        })

      order = create_order!(center_a)
      refund = create_refund!(actor_id, order.id)

      cs = Ash.Changeset.for_update(refund, :update, %{amount: 200}, actor: actor)

      # DSL-injected change populated the argument
      assert cs.arguments[:center_id] == center_a

      assert {:ok, updated} = Ash.update(cs, actor: actor)
      assert updated.amount == 200
    end

    test "update is forbidden when order's center_id is not in actor's units" do
      actor_id = Ash.UUID.generate()
      actor_center = Ash.UUID.generate()
      other_center = Ash.UUID.generate()

      actor =
        actor_with(["refund_dsl:*:update:at_own_unit"], actor_id, %{
          own_org_unit_ids: [actor_center]
        })

      order = create_order!(other_center)
      refund = create_refund!(actor_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "create succeeds when order's center_id is in actor's allowed units" do
      actor_id = Ash.UUID.generate()
      center = Ash.UUID.generate()

      actor =
        actor_with(["refund_dsl:*:create:at_own_unit"], actor_id, %{
          own_org_unit_ids: [center]
        })

      order = create_order!(center)

      result =
        RefundDsl
        |> Ash.Changeset.for_create(
          :create,
          %{author_id: actor_id, order_id: order.id, amount: 50},
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:ok, _} = result
    end

    test "create is forbidden when order's center_id is not in actor's units" do
      actor_id = Ash.UUID.generate()
      actor_center = Ash.UUID.generate()
      other_center = Ash.UUID.generate()

      actor =
        actor_with(["refund_dsl:*:create:at_own_unit"], actor_id, %{
          own_org_unit_ids: [actor_center]
        })

      order = create_order!(other_center)

      result =
        RefundDsl
        |> Ash.Changeset.for_create(
          :create,
          %{author_id: actor_id, order_id: order.id, amount: 50},
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "destroy succeeds when order's center_id is in actor's units" do
      actor_id = Ash.UUID.generate()
      center = Ash.UUID.generate()

      actor =
        actor_with(
          ["refund_dsl:*:destroy:at_own_unit", "refund_dsl:*:read:always"],
          actor_id,
          %{own_org_unit_ids: [center]}
        )

      order = create_order!(center)
      refund = create_refund!(actor_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
        |> Ash.destroy(actor: actor)

      assert :ok = result
    end
  end

  describe ":by_own_author scope (direct attribute, no relationship)" do
    test "update succeeds on author match without populating the argument" do
      actor_id = Ash.UUID.generate()

      actor = actor_with(["refund_dsl:*:update:by_own_author"], actor_id, %{})

      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(actor_id, order.id)

      cs = Ash.Changeset.for_update(refund, :update, %{amount: 200}, actor: actor)

      # Key correctness property: the DSL-injected change saw no permission
      # referencing ^arg(:center_id), so it left the argument unset.
      refute match?(%{center_id: value} when not is_nil(value), cs.arguments)

      assert {:ok, updated} = Ash.update(cs, actor: actor)
      assert updated.amount == 200
    end

    test "update is forbidden when author doesn't match" do
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      actor = actor_with(["refund_dsl:*:update:by_own_author"], actor_id, %{})

      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(other_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "DSL-driven argument injection" do
    test ":center_id argument is declared on every write action by the transformer" do
      # All three write actions should carry the injected argument.
      for action_name <- [:create, :update, :destroy] do
        action = Ash.Resource.Info.action(RefundDsl, action_name)

        assert Enum.any?(action.arguments, &(&1.name == :center_id)),
               "expected :center_id argument on action :#{action_name}"

        assert Enum.any?(action.changes, fn c ->
                 match?({AshGrant.Changes.ResolveArgument, _}, c.change)
               end),
               "expected ResolveArgument change on action :#{action_name}"
      end
    end

    test "change's :scopes_needing option lists exactly the scopes referencing ^arg(:center_id)" do
      update = Ash.Resource.Info.action(RefundDsl, :update)

      change =
        Enum.find(update.changes, fn c ->
          match?({AshGrant.Changes.ResolveArgument, _}, c.change)
        end)

      {_mod, opts} = change.change
      scopes = Keyword.fetch!(opts, :scopes_needing) |> Enum.sort()

      # Only :at_own_unit references ^arg(:center_id) on RefundDsl;
      # :by_own_author and :always do not.
      assert scopes == [:at_own_unit]
    end

    test "argument type is inferred from the leaf attribute type" do
      update = Ash.Resource.Info.action(RefundDsl, :update)
      arg = Enum.find(update.arguments, &(&1.name == :center_id))

      # Order.center_id is :uuid
      assert arg.type == Ash.Type.UUID
    end
  end
end

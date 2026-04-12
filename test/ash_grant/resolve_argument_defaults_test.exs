defmodule AshGrant.ResolveArgumentDefaultsTest do
  @moduledoc """
  Validates that `default_policies true` + `resolve_argument` compose cleanly:
  a resource can declare its entire authorization setup inside the `ash_grant`
  block with no explicit `policies` or per-action `argument`/`change` wiring.
  """
  use ExUnit.Case, async: false

  alias AshGrant.Test.Auth.{Order, RefundDefaults}

  setup do
    RefundDefaults
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    Order
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

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
    RefundDefaults
    |> Ash.Changeset.for_create(
      :create,
      %{author_id: author_id, order_id: order_id, amount: amount}
    )
    |> Ash.create!(authorize?: false)
  end

  describe "zero-boilerplate authorization via default_policies + resolve_argument" do
    test "update succeeds when the relational scope matches" do
      actor_id = Ash.UUID.generate()
      center = Ash.UUID.generate()

      actor =
        actor_with(["refund_defaults:*:update:at_own_unit"], actor_id, %{
          own_org_unit_ids: [center]
        })

      order = create_order!(center)
      refund = create_refund!(actor_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.amount == 200
    end

    test "update is forbidden when the relational scope does not match" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with(["refund_defaults:*:update:at_own_unit"], actor_id, %{
          own_org_unit_ids: [Ash.UUID.generate()]
        })

      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(actor_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "direct-attribute scope still works without loading order" do
      actor_id = Ash.UUID.generate()
      actor = actor_with(["refund_defaults:*:update:by_own_author"], actor_id, %{})

      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(actor_id, order.id)

      cs = Ash.Changeset.for_update(refund, :update, %{amount: 200}, actor: actor)

      # Lazy load skipped: no perm references ^arg(:center_id)
      refute match?(%{center_id: v} when not is_nil(v), cs.arguments)

      assert {:ok, _} = Ash.update(cs, actor: actor)
    end

    test "create succeeds with the relational scope" do
      actor_id = Ash.UUID.generate()
      center = Ash.UUID.generate()

      actor =
        actor_with(["refund_defaults:*:create:at_own_unit"], actor_id, %{
          own_org_unit_ids: [center]
        })

      order = create_order!(center)

      result =
        RefundDefaults
        |> Ash.Changeset.for_create(
          :create,
          %{author_id: actor_id, order_id: order.id, amount: 50},
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert {:ok, _} = result
    end

    test "read is filter-checked via default_policies" do
      actor_id = Ash.UUID.generate()
      order = create_order!(Ash.UUID.generate())
      _refund = create_refund!(actor_id, order.id)

      # With read:by_own_author, filter_check produces a matching filter
      granted = actor_with(["refund_defaults:*:read:by_own_author"], actor_id, %{})
      assert {:ok, [_]} = Ash.read(RefundDefaults, actor: granted)

      # Same actor, a different author's record should be invisible
      other_id = Ash.UUID.generate()
      _other_refund = create_refund!(other_id, order.id)

      assert {:ok, results} = Ash.read(RefundDefaults, actor: granted)
      assert length(results) == 1
      assert hd(results).author_id == actor_id
    end

    test "without any authorizing permission, write is forbidden" do
      actor_id = Ash.UUID.generate()
      actor = actor_with([], actor_id, %{})

      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(actor_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "DSL introspection" do
    test "transformer injected both argument and change despite no explicit wiring" do
      for action_name <- [:create, :update, :destroy] do
        action = Ash.Resource.Info.action(RefundDefaults, action_name)

        assert Enum.any?(action.arguments, &(&1.name == :center_id)),
               "expected :center_id argument on :#{action_name}"

        assert Enum.any?(action.changes, fn c ->
                 match?({AshGrant.Changes.ResolveArgument, _}, c.change)
               end),
               "expected ResolveArgument change on :#{action_name}"
      end
    end

    test "default_policies generated read + write policies" do
      policies = Ash.Policy.Info.policies(RefundDefaults)

      # One read policy (filter_check), one write policy (check), one generic action policy
      assert Enum.any?(policies, fn p ->
               Enum.any?(p.condition, fn
                 {Ash.Policy.Check.ActionType, opts} -> opts[:type] == [:read]
                 _ -> false
               end)
             end),
             "expected a default-generated read policy"

      assert Enum.any?(policies, fn p ->
               Enum.any?(p.condition, fn
                 {Ash.Policy.Check.ActionType, opts} ->
                   opts[:type] == [:create, :update, :destroy]

                 _ ->
                   false
               end)
             end),
             "expected a default-generated write policy"
    end
  end
end

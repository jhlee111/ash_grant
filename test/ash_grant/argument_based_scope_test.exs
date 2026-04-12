defmodule AshGrant.ArgumentBasedScopeTest do
  @moduledoc """
  Reference implementation + tests for the "argument-based scope with
  resource-local lazy argument resolution" pattern.

  Why: when a resource (Refund) needs to authorize against a value reachable
  only through a relationship (order.center_id), the obvious approach — a
  relational scope `expr(order.center_id in ^actor(:own_org_unit_ids))` —
  forces the DB-query fallback path and struggles with composite scopes,
  function-wrapped expressions, and pre/post-state ambiguity.

  This pattern instead:
    1. Declares scopes that compare actor attributes to an *argument*
       (`^arg(:center_id)`), keeping expressions in-memory-evaluable.
    2. Pushes the relationship traversal into a `change` module that runs
       before the action — but only when the actor's permissions actually
       reference that argument (cheap scopes skip the load entirely).

  Tests verify:
    - Load runs when a relevant scope is in play, authorization succeeds on
      match and fails on mismatch.
    - Load is skipped when no in-play scope needs the argument, and
      authorization still works against direct-attribute scopes.
  """
  use ExUnit.Case, async: false

  alias AshGrant.Test.Auth.{Order, Refund}

  setup do
    # ETS data layer persists across tests; clear between runs.
    Refund |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))
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
    Refund
    |> Ash.Changeset.for_create(:create, %{
      author_id: author_id,
      order_id: order_id,
      amount: amount
    })
    |> Ash.create!(authorize?: false)
  end

  describe "at_own_unit scope (needs order.center_id)" do
    test "update succeeds when order's center_id is in actor's allowed units, and order is loaded" do
      actor_id = Ash.UUID.generate()
      center_a = Ash.UUID.generate()
      center_b = Ash.UUID.generate()

      actor =
        actor_with(["refund:*:update:at_own_unit"], actor_id, %{
          own_org_unit_ids: [center_a, center_b]
        })

      order = create_order!(center_a)
      refund = create_refund!(actor_id, order.id)

      cs =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)

      result = Ash.update(cs, actor: actor)

      assert {:ok, updated} = result
      assert updated.amount == 200
    end

    test "update is forbidden when order's center_id is not in actor's units" do
      actor_id = Ash.UUID.generate()
      actor_center = Ash.UUID.generate()
      other_center = Ash.UUID.generate()

      actor =
        actor_with(["refund:*:update:at_own_unit"], actor_id, %{own_org_unit_ids: [actor_center]})

      order = create_order!(other_center)
      refund = create_refund!(actor_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "by_own_author scope (direct attribute, no relationship)" do
    test "update succeeds on author match WITHOUT loading order (lazy load is skipped)" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with(
          ["refund:*:update:by_own_author"],
          actor_id,
          # No own_org_unit_ids — proves scope doesn't need :center_id
          %{}
        )

      # Order's center_id is irrelevant here
      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(actor_id, order.id)

      # Capture the changeset post-change to verify load did NOT happen.
      # We do this by building the changeset, running changes, then asserting
      # on its context before submitting.
      cs =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)

      assert cs.context[:ash_grant_test_loaded_order?] == false,
             "expected load to be skipped for :by_own_author scope"

      # And full execution still succeeds
      assert {:ok, updated} = Ash.update(cs, actor: actor)
      assert updated.amount == 200
    end

    test "update is forbidden when author doesn't match" do
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      actor = actor_with(["refund:*:update:by_own_author"], actor_id, %{})

      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(other_id, order.id)

      result =
        refund
        |> Ash.Changeset.for_update(:update, %{amount: 200}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "lazy-load introspection" do
    test "load runs when actor has a permission referencing ^arg(:center_id)" do
      actor_id = Ash.UUID.generate()
      center = Ash.UUID.generate()

      actor =
        actor_with(["refund:*:update:at_own_unit"], actor_id, %{own_org_unit_ids: [center]})

      order = create_order!(center)
      refund = create_refund!(actor_id, order.id)

      cs = Ash.Changeset.for_update(refund, :update, %{amount: 200}, actor: actor)

      assert cs.context[:ash_grant_test_loaded_order?] == true
      assert cs.arguments[:center_id] == center
    end

    test "load skipped when actor has only a non-referencing permission" do
      actor_id = Ash.UUID.generate()
      actor = actor_with(["refund:*:update:by_own_author"], actor_id, %{})

      order = create_order!(Ash.UUID.generate())
      refund = create_refund!(actor_id, order.id)

      cs = Ash.Changeset.for_update(refund, :update, %{amount: 200}, actor: actor)

      assert cs.context[:ash_grant_test_loaded_order?] == false
      refute Map.has_key?(cs.arguments, :center_id) and cs.arguments[:center_id] != nil
    end
  end
end

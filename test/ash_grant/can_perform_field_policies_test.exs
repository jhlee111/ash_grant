defmodule AshGrant.CanPerformFieldPoliciesTest do
  @moduledoc """
  A resource with both `default_field_policies(true)` and `can_perform_actions`
  must return the generated CanPerform calculations as booleans, not
  `%Ash.ForbiddenField{}`.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.FieldPolicyCanPerformRecord
  alias AshGrant.Transformers.AddCanPerformCalculations
  alias AshGrant.Transformers.AddFieldPolicies

  defp create_record!(owner_id) do
    FieldPolicyCanPerformRecord
    |> Ash.Changeset.for_create(:create, %{title: "t", secret: "s", owner_id: owner_id},
      authorize?: false
    )
    |> Ash.create!()
  end

  test "AddCanPerformCalculations sorts before AddFieldPolicies in either input order" do
    for transformers <- [
          [AddFieldPolicies, AddCanPerformCalculations],
          [AddCanPerformCalculations, AddFieldPolicies]
        ] do
      assert Spark.Dsl.Transformer.sort(transformers) ==
               [AddCanPerformCalculations, AddFieldPolicies]
    end
  end

  test "the field policy cache covers the generated calculations" do
    cache =
      Spark.Dsl.Extension.get_persisted(FieldPolicyCanPerformRecord, :fields_to_field_policies)

    assert Map.has_key?(cache, :can_update?)
    assert Map.has_key?(cache, :can_destroy?)
  end

  test "an authorized read loads the calculations as booleans" do
    mine = create_record!("u1")
    other = create_record!("u2")

    actor = %{
      id: "u1",
      permissions: [
        "fieldpolicycanperformrecord:*:read:always",
        "fieldpolicycanperformrecord:*:update:own"
      ]
    }

    results =
      Ash.read!(FieldPolicyCanPerformRecord,
        actor: actor,
        load: [:can_update?, :can_destroy?]
      )

    loaded = Map.new(results, &{&1.id, {&1.can_update?, &1.can_destroy?}})

    assert loaded[mine.id] == {true, false}
    assert loaded[other.id] == {false, false}
  end
end

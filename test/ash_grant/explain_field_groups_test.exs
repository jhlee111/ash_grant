defmodule AshGrant.ExplainFieldGroupsTest do
  @moduledoc """
  `AshGrant.explain/4` reports the field groups `AshGrant.Introspect.can?/4` and the
  runtime apply (#223).

  A group-less grant leaves the actor unrestricted, so it collapses the union of
  field groups to `[]` (#116). `explain/4` used to drop the group-less grant and
  report the other grant's group instead.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.SensitiveRecord

  defp actor(permissions), do: %{id: Ash.UUID.generate(), permissions: permissions}

  defp introspect_groups(actor) do
    {:allow, %{field_groups: groups}} = AshGrant.Introspect.can?(SensitiveRecord, :read, actor)
    groups
  end

  test "a group-less grant next to a field-group grant reports no restriction" do
    actor =
      actor(["sensitiverecord:*:read:always", "sensitiverecord:*:read:always:public"])

    explanation = AshGrant.explain(SensitiveRecord, :read, actor)

    assert explanation.decision == :allow
    assert explanation.field_groups == []
    assert explanation.field_groups == introspect_groups(actor)
    assert to_string(explanation) =~ "actor has no field_group restriction"
  end

  test "field-group grants alone report their groups" do
    actor =
      actor([
        "sensitiverecord:*:read:always:public",
        "sensitiverecord:*:read:always:sensitive"
      ])

    explanation = AshGrant.explain(SensitiveRecord, :read, actor)

    assert Enum.sort(explanation.field_groups) == ["public", "sensitive"]
    assert explanation.field_groups == introspect_groups(actor)
  end

  test "a group-less grant alone reports no restriction" do
    actor = actor(["sensitiverecord:*:read:always"])

    assert AshGrant.explain(SensitiveRecord, :read, actor).field_groups == []
  end
end

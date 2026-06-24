defmodule AshGrant.FieldGroupGrantsTest do
  @moduledoc """
  Unit + property tests for `AshGrant.Evaluator.field_group_grants/5`
  (issue #117 phase ②, stage 1).

  The helper returns the ALLOW permissions that grant visibility of a required
  field group on some rows — including INSTANCE permissions (which
  `get_all_field_groups/4` discards) and keeping each grant's scope / instance_id
  intact, so a per-record predicate can be built from them later
  (`AshGrant.FieldFilterCheck`).

  Uses `AshGrant.Test.SensitiveRecord` for its field-group inheritance chain:
  `:public ⊂ :sensitive ⊂ :confidential` (resource_name "sensitiverecord").
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrant.Evaluator
  alias AshGrant.Test.SensitiveRecord

  defp groups(perms, required, action \\ "read", action_type \\ nil) do
    Evaluator.field_group_grants(perms, SensitiveRecord, action, required, action_type)
  end

  describe "direct + inheritance reach" do
    test "a direct grant of the required group contributes" do
      grants = groups(["sensitiverecord:*:read:always:public"], :public)
      assert [%{field_group: "public", scope: "always"}] = grants
    end

    test "holding a child group grants its ancestors (sensitive reaches public)" do
      grants = groups(["sensitiverecord:*:read:always:sensitive"], :public)
      assert [%{field_group: "sensitive"}] = grants
    end

    test "holding confidential reaches public and sensitive (transitive)" do
      perms = ["sensitiverecord:*:read:always:confidential"]
      assert [%{field_group: "confidential"}] = groups(perms, :public)
      assert [%{field_group: "confidential"}] = groups(perms, :sensitive)
      assert [%{field_group: "confidential"}] = groups(perms, :confidential)
    end

    test "holding a parent group does NOT grant a descendant (public !-> confidential)" do
      assert groups(["sensitiverecord:*:read:always:public"], :confidential) == []
    end
  end

  describe "group-less grants" do
    test "a group-less (4-part) allow contributes to every group" do
      perms = ["sensitiverecord:*:read:always"]
      assert [%{field_group: nil}] = groups(perms, :public)
      assert [%{field_group: nil}] = groups(perms, :sensitive)
      assert [%{field_group: nil}] = groups(perms, :confidential)
    end
  end

  describe "instance permissions (the get_all_field_groups blind spot)" do
    test "an instance permission with a field_group is included, instance_id intact" do
      grants = groups(["sensitiverecord:rec1:read::sensitive"], :sensitive)
      assert [%{field_group: "sensitive", instance_id: "rec1"}] = grants
    end

    test "for comparison, get_all_field_groups drops the same instance grant" do
      perms = ["sensitiverecord:rec1:read::sensitive"]
      assert Evaluator.get_all_field_groups(perms, "sensitiverecord", "read") == []
    end
  end

  describe "scope is retained for predicate building" do
    test "a non-trivial scope is preserved on the returned grant" do
      assert [%{scope: "own"}] = groups(["sensitiverecord:*:read:own:sensitive"], :sensitive)
    end
  end

  describe "exclusions" do
    test "denies are excluded (they are row-level, handled by the read policy)" do
      perms = ["sensitiverecord:*:read:always:sensitive", "!sensitiverecord:*:read:always"]
      assert [%{field_group: "sensitive", deny: false}] = groups(perms, :sensitive)
    end

    test "permissions for a different resource or action are excluded" do
      perms = [
        "other:*:read:always:public",
        "sensitiverecord:*:update:always:public"
      ]

      assert groups(perms, :public, "read") == []
    end

    test "a grant that does not reach the required group is excluded" do
      # :public grant does not reach :confidential
      perms = ["sensitiverecord:*:read:always:public", "sensitiverecord:*:read:own:sensitive"]
      assert groups(perms, :confidential) == []
    end
  end

  describe "union — multiple contributing grants" do
    test "all reaching grants are returned (for predicate OR-combination)" do
      perms = [
        "sensitiverecord:*:read:always:public",
        "sensitiverecord:*:read:own:sensitive"
      ]

      # :public is reached by the direct :public grant AND the :sensitive grant
      public_grants = groups(perms, :public)
      assert length(public_grants) == 2
      assert Enum.map(public_grants, & &1.field_group) |> Enum.sort() == ["public", "sensitive"]

      # :sensitive is reached only by the :sensitive grant
      assert [%{field_group: "sensitive", scope: "own"}] = groups(perms, :sensitive)
    end
  end

  describe "action_type matching" do
    test "a read* type-wildcard grant matches a custom read action via action_type" do
      perms = ["sensitiverecord:*:read*:always:sensitive"]
      assert [%{field_group: "sensitive"}] = groups(perms, :sensitive, "by_dept", :read)
    end
  end

  describe "properties" do
    property "a group-less allow always contributes to every defined group" do
      check all(
              group <- member_of([:public, :sensitive, :confidential]),
              scope <- member_of(["always", "own"])
            ) do
        grants = groups(["sensitiverecord:*:read:#{scope}"], group)
        assert [%{field_group: nil}] = grants
      end
    end

    property "a direct grant naming exactly G contributes to G" do
      check all(group <- member_of([:public, :sensitive, :confidential])) do
        grants = groups(["sensitiverecord:*:read:always:#{group}"], group)
        assert [%{field_group: g}] = grants
        assert g == to_string(group)
      end
    end
  end
end

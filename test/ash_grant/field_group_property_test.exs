defmodule AshGrant.FieldGroupPropertyTest do
  @moduledoc """
  Property-based tests for field group features:
  - Permission 5-part format roundtrip with field_group
  - Evaluator get_field_group/3 and get_all_field_groups/3
  - Field group inheritance properties
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrant.{Permission, Evaluator}

  # ============================================
  # Generators
  # ============================================

  defp resource_gen do
    string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
  end

  defp action_gen do
    string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
  end

  defp scope_gen do
    one_of([
      constant("all"),
      constant("own"),
      string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
    ])
  end

  defp field_group_gen do
    one_of([
      constant(nil),
      constant("public"),
      constant("sensitive"),
      constant("confidential"),
      string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
    ])
  end

  defp non_nil_field_group_gen do
    one_of([
      constant("public"),
      constant("sensitive"),
      constant("confidential"),
      string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
    ])
  end

  defp instance_id_gen do
    one_of([
      constant("*"),
      string(:alphanumeric, min_length: 3, max_length: 15) |> map(&("inst_" <> &1))
    ])
  end

  defp permission_5part_gen do
    gen all(
          resource <- resource_gen(),
          instance_id <- instance_id_gen(),
          action <- action_gen(),
          scope <- scope_gen(),
          field_group <- field_group_gen(),
          deny <- boolean()
        ) do
      %Permission{
        resource: resource,
        instance_id: instance_id,
        action: action,
        scope: scope,
        field_group: field_group,
        deny: deny
      }
    end
  end

  # ============================================
  # Permission Parse/ToString Roundtrip
  # ============================================

  describe "5-part permission roundtrip" do
    property "to_string |> parse preserves field_group" do
      check all(perm <- permission_5part_gen()) do
        str = Permission.to_string(perm)
        {:ok, parsed} = Permission.parse(str)

        assert parsed.resource == perm.resource
        assert parsed.action == perm.action
        assert parsed.scope == perm.scope
        assert parsed.field_group == perm.field_group
        assert parsed.deny == perm.deny
      end
    end

    property "parse |> to_string |> parse is idempotent" do
      check all(perm <- permission_5part_gen()) do
        str1 = Permission.to_string(perm)
        {:ok, parsed1} = Permission.parse(str1)
        str2 = Permission.to_string(parsed1)
        {:ok, parsed2} = Permission.parse(str2)

        assert parsed1.field_group == parsed2.field_group
        assert str1 == str2
      end
    end

    property "5-part string has exactly 4 colons when field_group present" do
      check all(perm <- permission_5part_gen(), perm.field_group != nil) do
        str = Permission.to_string(perm)
        base_str = if perm.deny, do: String.slice(str, 1..-1//1), else: str
        colon_count = base_str |> String.graphemes() |> Enum.count(&(&1 == ":"))
        assert colon_count == 4
      end
    end

    property "4-part string has exactly 3 colons when field_group is nil" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              deny <- boolean()
            ) do
        perm = %Permission{
          resource: resource,
          instance_id: "*",
          action: action,
          scope: scope,
          field_group: nil,
          deny: deny
        }

        str = Permission.to_string(perm)
        base_str = if deny, do: String.slice(str, 1..-1//1), else: str
        colon_count = base_str |> String.graphemes() |> Enum.count(&(&1 == ":"))
        assert colon_count == 3
      end
    end
  end

  # ============================================
  # Evaluator Field Group Functions
  # ============================================

  describe "get_field_group/3" do
    property "returns field_group when permission matches" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = ["#{resource}:*:#{action}:#{scope}:#{field_group}"]
        result = Evaluator.get_field_group(permissions, resource, action)

        assert result == field_group
      end
    end

    property "returns nil when denied" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = [
          "#{resource}:*:#{action}:#{scope}:#{field_group}",
          "!#{resource}:*:#{action}:always"
        ]

        assert Evaluator.get_field_group(permissions, resource, action) == nil
      end
    end

    property "returns nil when no matching permission" do
      check all(
              resource <- resource_gen(),
              action <- action_gen()
            ) do
        permissions = ["other_resource:*:#{action}:always:public"]
        result = Evaluator.get_field_group(permissions, resource, action)
        assert result == nil
      end
    end

    property "4-part permission returns nil for field_group" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        permissions = ["#{resource}:*:#{action}:#{scope}"]
        result = Evaluator.get_field_group(permissions, resource, action)
        assert result == nil
      end
    end
  end

  describe "get_all_field_groups/3" do
    property "returns unique field groups" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        # Duplicate permissions with same field_group
        permissions = [
          "#{resource}:*:#{action}:#{scope}:#{field_group}",
          "#{resource}:*:#{action}:#{scope}:#{field_group}"
        ]

        groups = Evaluator.get_all_field_groups(permissions, resource, action)
        assert groups == Enum.uniq(groups)
      end
    end

    property "returns empty list when denied" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              groups <- list_of(non_nil_field_group_gen(), min_length: 1, max_length: 3)
            ) do
        allow_perms = Enum.map(groups, &"#{resource}:*:#{action}:always:#{&1}")
        deny_perm = "!#{resource}:*:#{action}:always"

        result = Evaluator.get_all_field_groups(allow_perms ++ [deny_perm], resource, action)
        assert result == []
      end
    end

    property "returns all distinct field groups from matching permissions" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              fg1 <- non_nil_field_group_gen(),
              fg2 <- non_nil_field_group_gen() |> filter(&(&1 != fg1))
            ) do
        permissions = [
          "#{resource}:*:#{action}:always:#{fg1}",
          "#{resource}:*:#{action}:always:#{fg2}"
        ]

        groups = Evaluator.get_all_field_groups(permissions, resource, action)
        assert fg1 in groups
        assert fg2 in groups
      end
    end

    property "4-part permissions contribute no field_groups" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        permissions = ["#{resource}:*:#{action}:#{scope}"]
        groups = Evaluator.get_all_field_groups(permissions, resource, action)
        assert groups == []
      end
    end
  end

  # ============================================
  # 5-Part with Instance ID Properties
  # ============================================

  describe "5-part with instance_id" do
    property "roundtrip preserves instance_id in 5-part" do
      check all(perm <- permission_5part_gen()) do
        str = Permission.to_string(perm)
        {:ok, parsed} = Permission.parse(str)

        assert parsed.instance_id == perm.instance_id
        assert parsed.field_group == perm.field_group
      end
    end

    property "5-part instance permission matches_instance? when instance_id != *" do
      check all(
              resource <- resource_gen(),
              instance_id <-
                string(:alphanumeric, min_length: 3, max_length: 15) |> map(&("inst_" <> &1)),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        perm =
          Permission.parse!("#{resource}:#{instance_id}:#{action}:#{scope}:#{field_group}")

        assert Permission.matches_instance?(perm, instance_id, action)
        refute Permission.matches_instance?(perm, "other_id", action)
      end
    end

    property "5-part RBAC does not match instance query" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        perm = Permission.parse!("#{resource}:*:#{action}:#{scope}:#{field_group}")
        refute Permission.matches_instance?(perm, "some_instance", action)
      end
    end
  end

  # ============================================
  # 5-Part Deny Properties
  # ============================================

  describe "5-part deny semantics" do
    property "5-part deny blocks has_access?" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = [
          "#{resource}:*:#{action}:#{scope}:#{field_group}",
          "!#{resource}:*:#{action}:#{scope}:#{field_group}"
        ]

        refute Evaluator.has_access?(permissions, resource, action)
      end
    end

    property "5-part deny blocks get_field_group" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = [
          "#{resource}:*:#{action}:#{scope}:#{field_group}",
          "!#{resource}:*:#{action}:always"
        ]

        assert Evaluator.get_field_group(permissions, resource, action) == nil
      end
    end

    property "5-part deny on different action does not block" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              other_action <- action_gen() |> filter(&(&1 != action)),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = [
          "#{resource}:*:#{action}:#{scope}:#{field_group}",
          "!#{resource}:*:#{other_action}:always:#{field_group}"
        ]

        assert Evaluator.has_access?(permissions, resource, action)
      end
    end
  end

  # ============================================
  # 5-Part Wildcard Properties
  # ============================================

  describe "5-part wildcard evaluation" do
    property "5-part with action wildcard matches any action" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = ["#{resource}:*:*:#{scope}:#{field_group}"]
        assert Evaluator.has_access?(permissions, resource, action)
        assert Evaluator.get_field_group(permissions, resource, action) == field_group
      end
    end

    property "5-part with resource wildcard matches any resource" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = ["*:*:#{action}:#{scope}:#{field_group}"]
        assert Evaluator.has_access?(permissions, resource, action)
        assert Evaluator.get_field_group(permissions, resource, action) == field_group
      end
    end

    property "5-part with action type wildcard requires action_type" do
      check all(
              resource <- resource_gen(),
              prefix <-
                string(:alphanumeric, min_length: 1, max_length: 5) |> map(&String.downcase/1),
              action_name <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              scope <- scope_gen(),
              field_group <- non_nil_field_group_gen()
            ) do
        permissions = ["#{resource}:*:#{prefix}*:#{scope}:#{field_group}"]
        # Without action_type, prefix* never matches
        refute Evaluator.has_access?(permissions, resource, action_name)
      end
    end
  end

  # ============================================
  # Field Group Inheritance Properties
  # ============================================

  describe "field group inheritance properties" do
    # Using the SensitiveRecord resource: public -> sensitive -> confidential

    property "resolved field group always includes its own fields" do
      check all(group <- member_of([:public, :sensitive, :confidential])) do
        fg_def = AshGrant.Info.get_field_group(AshGrant.Test.SensitiveRecord, group)
        resolved = AshGrant.Info.resolve_field_group(AshGrant.Test.SensitiveRecord, group)

        for field <- fg_def.fields do
          assert field in resolved.fields,
                 "Expected #{field} in resolved fields for #{group}"
        end
      end
    end

    property "child field group always contains parent fields" do
      check all(
              {child, parent} <-
                member_of([{:sensitive, :public}, {:confidential, :sensitive}])
            ) do
        parent_resolved =
          AshGrant.Info.resolve_field_group(AshGrant.Test.SensitiveRecord, parent)

        child_resolved = AshGrant.Info.resolve_field_group(AshGrant.Test.SensitiveRecord, child)

        for field <- parent_resolved.fields do
          assert field in child_resolved.fields,
                 "Expected parent field #{field} in child #{child}"
        end
      end
    end

    property "resolved field count is monotonically increasing along inheritance chain" do
      public = AshGrant.Info.resolve_field_group(AshGrant.Test.SensitiveRecord, :public)
      sensitive = AshGrant.Info.resolve_field_group(AshGrant.Test.SensitiveRecord, :sensitive)

      confidential =
        AshGrant.Info.resolve_field_group(AshGrant.Test.SensitiveRecord, :confidential)

      assert length(public.fields) <= length(sensitive.fields)
      assert length(sensitive.fields) <= length(confidential.fields)
    end
  end
end

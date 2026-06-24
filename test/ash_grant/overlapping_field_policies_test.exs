defmodule AshGrant.OverlappingFieldPoliciesTest do
  use ExUnit.Case, async: true

  describe "deduplicated field policies with overlapping :all groups" do
    test "each field appears in exactly one non-catch-all policy" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.OverlappingRecord)

      # Exclude the catch-all policy (which Ash expands from :* to all fields)
      group_policies = Enum.reject(field_policies, &catch_all?/1)

      all_fields = Enum.flat_map(group_policies, & &1.fields)
      unique_fields = Enum.uniq(all_fields)

      assert length(all_fields) == length(unique_fields),
             "Fields appear in multiple policies: #{inspect(all_fields -- unique_fields)}"
    end

    test "total field count across group policies equals unique attribute count" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.OverlappingRecord)
      group_policies = Enum.reject(field_policies, &catch_all?/1)

      policy_field_count = group_policies |> Enum.flat_map(& &1.fields) |> length()

      # 6 public non-PK attributes: name, description, price, cost, supplier, tax_code
      # (:id is excluded as a primary key — not a valid field policy target)
      assert policy_field_count == 6
    end

    test "generates correct number of group policies plus catch-all" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.OverlappingRecord)
      # 3 field groups + 1 catch-all = 4
      assert length(field_policies) == 4
    end

    test "public fields are in public policy only" do
      group_policies = non_catch_all_policies(AshGrant.Test.OverlappingRecord)

      public_policy = find_policy_by_group(group_policies, :public)
      assert public_policy != nil
      assert :name in public_policy.fields
      assert :description in public_policy.fields
      assert :price in public_policy.fields
    end

    test "internal fields exclude public and tax_code fields" do
      group_policies = non_catch_all_policies(AshGrant.Test.OverlappingRecord)

      internal_policy = find_policy_by_group(group_policies, :internal)
      assert internal_policy != nil

      # cost and supplier should be in internal (not in public, not tax_code)
      assert :cost in internal_policy.fields
      assert :supplier in internal_policy.fields

      # public fields should NOT be in internal policy
      refute :name in internal_policy.fields
      refute :description in internal_policy.fields
      refute :price in internal_policy.fields

      # tax_code excluded by except:
      refute :tax_code in internal_policy.fields
    end

    test "admin policy gets only remaining fields (tax_code)" do
      group_policies = non_catch_all_policies(AshGrant.Test.OverlappingRecord)

      admin_policy = find_policy_by_group(group_policies, :admin)
      assert admin_policy != nil
      assert :tax_code in admin_policy.fields

      # Should only have tax_code (the one field not claimed by earlier groups)
      assert length(admin_policy.fields) == 1
    end
  end

  describe "non-overlapping field_groups still work" do
    test "SensitiveRecord field policies unchanged" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
      # 3 field groups + 1 catch-all = 4
      assert length(field_policies) == 4

      group_policies = Enum.reject(field_policies, &catch_all?/1)

      public_policy = find_policy_by_group(group_policies, :public)
      assert :name in public_policy.fields
      assert :department in public_policy.fields
      assert :position in public_policy.fields

      sensitive_policy = find_policy_by_group(group_policies, :sensitive)
      assert :phone in sensitive_policy.fields
      assert :address in sensitive_policy.fields

      confidential_policy = find_policy_by_group(group_policies, :confidential)
      assert :salary in confidential_policy.fields
      assert :email in confidential_policy.fields
    end

    test "ExceptRecord field policies unchanged" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.ExceptRecord)
      # 2 field groups + 1 catch-all = 3
      assert length(field_policies) == 3
    end
  end

  # Helpers

  defp catch_all?(policy) do
    Enum.any?(policy.policies, fn check ->
      check.check_module == Ash.Policy.Check.Static
    end)
  end

  defp non_catch_all_policies(resource) do
    resource
    |> Ash.Policy.Info.field_policies()
    |> Enum.reject(&catch_all?/1)
  end

  defp find_policy_by_group(policies, group_name) do
    Enum.find(policies, fn policy ->
      Enum.any?(policy.policies, fn check ->
        check.check_module == AshGrant.FieldFilterCheck and
          check.check_opts[:field_group] == group_name
      end)
    end)
  end
end

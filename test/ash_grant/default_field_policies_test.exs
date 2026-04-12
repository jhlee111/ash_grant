defmodule AshGrant.DefaultFieldPoliciesTest do
  use ExUnit.Case, async: true

  describe "auto-generated field policies" do
    test "field policies are generated when default_field_policies is true" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
      assert field_policies != []
    end

    test "generates field policy for each field group plus catch-all" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
      # 3 field groups + 1 catch-all = 4 field policies
      assert length(field_policies) == 4
    end

    test "catch-all field policy exists" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
      # After Ash processes the :* catch-all, it expands to all non-pkey fields.
      # Check that there's a policy that covers fields not in any group.
      all_field_group_fields =
        field_policies
        |> Enum.flat_map(& &1.fields)
        |> Enum.uniq()

      # All public non-pkey fields should be covered
      assert :name in all_field_group_fields
      assert :salary in all_field_group_fields
    end

    test "public fields have public field_group check" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
      public_policy = Enum.find(field_policies, &(:name in &1.fields))
      assert public_policy != nil
      assert :department in public_policy.fields
      assert :position in public_policy.fields
    end

    test "sensitive fields have sensitive field_group check" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
      sensitive_policy = Enum.find(field_policies, &(:phone in &1.fields))
      assert sensitive_policy != nil
      assert :address in sensitive_policy.fields
    end

    test "confidential fields have confidential field_group check" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
      confidential_policy = Enum.find(field_policies, &(:salary in &1.fields))
      assert confidential_policy != nil
      assert :email in confidential_policy.fields
    end

    test "field policies use FieldCheck with correct field_group" do
      field_policies = Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)

      # Find the policy for public fields
      public_policy = Enum.find(field_policies, &(:name in &1.fields))
      assert public_policy != nil

      [check] = public_policy.policies
      assert check.check_module == AshGrant.FieldCheck
      assert check.check_opts[:field_group] == :public
    end
  end

  describe "field_group :all excludes PK/private from field policies (issue #51)" do
    test "resource with timestamps and field_group :all compiles without error" do
      defmodule TimestampResource do
        use Ash.Resource,
          domain: AshGrant.Test.Domain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshGrant],
          validate_domain_inclusion?: false

        ash_grant do
          resolver(fn _, _ -> [] end)
          default_policies(true)
          default_field_policies(true)
          resource_name("timestamp_res")
          scope(:always, true)

          field_group(:admin, :all)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, public?: true)
          attribute(:status, :string, public?: true)
          create_timestamp(:created_at)
          update_timestamp(:updated_at)
        end

        actions do
          defaults([:read, create: :*])
        end
      end

      # Should compile without Spark.Error.DslError about invalid field references
      assert Code.ensure_loaded?(TimestampResource)

      # Field policies should not contain PK or private timestamp fields
      field_policies = Ash.Policy.Info.field_policies(TimestampResource)
      all_policy_fields = Enum.flat_map(field_policies, & &1.fields) |> Enum.uniq()

      refute :id in all_policy_fields
      refute :created_at in all_policy_fields
      refute :updated_at in all_policy_fields

      # Public fields should be present
      assert :name in all_policy_fields
      assert :status in all_policy_fields
    end
  end

  describe "default_field_policies info" do
    test "returns true when enabled" do
      assert AshGrant.Info.default_field_policies(AshGrant.Test.SensitiveRecord) == true
    end
  end
end

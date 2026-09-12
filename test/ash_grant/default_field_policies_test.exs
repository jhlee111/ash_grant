defmodule AshGrant.DefaultFieldPoliciesTest do
  use ExUnit.Case, async: true

  @public_fields [:name, :department, :position]
  @sensitive_fields [:phone, :address]
  @confidential_fields [:salary, :email]
  @all_fields @public_fields ++ @sensitive_fields ++ @confidential_fields

  # Select a policy by its exact field set, never by `field in policy.fields`.
  # The `:*` catch-all expands to every non-pkey field, so it contains each
  # group's fields too — a positional `Enum.find/2` returns whichever Ash
  # happens to list first, and that order is reversed under OTP 28 relative to
  # OTP 27. Order does not affect authorization (Ash evaluates every field
  # policy that applies to a field), so selection, not ordering, is what a test
  # has to be careful about.
  defp policy_for_fields(fields) do
    wanted = Enum.sort(fields)

    AshGrant.Test.SensitiveRecord
    |> Ash.Policy.Info.field_policies()
    |> Enum.find(&(Enum.sort(&1.fields) == wanted))
  end

  defp catch_all_policy, do: policy_for_fields(@all_fields)

  defp policy_field_sets do
    AshGrant.Test.SensitiveRecord
    |> Ash.Policy.Info.field_policies()
    |> Enum.map(& &1.fields)
  end

  # A group's policy must exist, cover exactly that group, and carry the
  # FieldFilterCheck naming it — which is what these tests have always claimed
  # in their names while asserting only the field list.
  defp assert_group_policy(fields, group) do
    policy = policy_for_fields(fields)

    assert policy != nil,
           "no field policy covers exactly the #{inspect(group)} group " <>
             "#{inspect(Enum.sort(fields))}; got #{inspect(policy_field_sets())}"

    assert [check] = policy.policies
    assert check.check_module == AshGrant.FieldFilterCheck
    assert check.check_opts[:field_group] == group
  end

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
      # The `:*` catch-all expands to every non-pkey field, so it is the policy
      # whose field set is the union of all the groups'. Asserting only that
      # some policy mentions :name and :salary would pass on the group policies
      # alone, catch-all or not.
      catch_all = catch_all_policy()

      assert catch_all != nil,
             "no field policy covers every non-pkey field; got " <>
               inspect(policy_field_sets())

      assert Enum.sort(catch_all.fields) == Enum.sort(@all_fields)
    end

    test "public fields have public field_group check" do
      assert_group_policy(@public_fields, :public)
    end

    test "sensitive fields have sensitive field_group check" do
      assert_group_policy(@sensitive_fields, :sensitive)
    end

    test "confidential fields have confidential field_group check" do
      assert_group_policy(@confidential_fields, :confidential)
    end

    test "every generated policy is a FieldFilterCheck except the catch-all" do
      by_check =
        Ash.Policy.Info.field_policies(AshGrant.Test.SensitiveRecord)
        |> Enum.group_by(fn policy ->
          policy.policies |> Enum.map(& &1.check_module) |> Enum.uniq()
        end)

      assert MapSet.new(Map.keys(by_check)) ==
               MapSet.new([[AshGrant.FieldFilterCheck], [Ash.Policy.Check.Static]])

      # One Static policy, and it is the catch-all — not a group that quietly
      # lost its check.
      assert [catch_all] = by_check[[Ash.Policy.Check.Static]]
      assert Enum.sort(catch_all.fields) == Enum.sort(@all_fields)

      groups =
        by_check[[AshGrant.FieldFilterCheck]]
        |> Enum.map(fn policy -> hd(policy.policies).check_opts[:field_group] end)
        |> Enum.sort()

      assert groups == [:confidential, :public, :sensitive]
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

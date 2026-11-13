defmodule AshGrant.DenyFieldsByDefaultTest do
  @moduledoc """
  Tests for `deny_fields_by_default`: a group-less grant reads the row but opens
  no field group, and fields outside every group are forbidden.
  """
  # Not async: capture_io(:stderr, ...) swaps the VM-wide :standard_error device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshGrant.{Evaluator, Info, Introspect}

  alias AshGrant.Test.{
    DenyFieldsAppConfigRecord,
    DenyFieldsDisjointRecord,
    DenyFieldsDomainRecord,
    DenyFieldsExceptRecord,
    DenyFieldsOptOutRecord,
    DenyFieldsRecord,
    SensitiveRecord
  }

  defmodule PolicyTest do
    @moduledoc false
    use AshGrant.PolicyTest

    resource(AshGrant.Test.DenyFieldsRecord)

    actor(:row_only, %{permissions: ["denyfieldsrecord:*:read:always"]})
    actor(:sensitive, %{permissions: ["denyfieldsrecord:*:read:always:sensitive"]})
  end

  defp create!(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  defp read_one!(resource, id, permissions) do
    resource
    |> Ash.read!(actor: %{permissions: permissions})
    |> Enum.find(&(&1.id == id))
  end

  defp forbidden?(value), do: match?(%Ash.ForbiddenField{}, value)

  defp record! do
    create!(DenyFieldsRecord, %{
      name: "Ada",
      department: "Eng",
      phone: "555-1234",
      salary: 100,
      notes: "private"
    })
  end

  describe "resource-level flag" do
    test "Info reports the resource option" do
      assert Info.deny_fields_by_default?(DenyFieldsRecord)
      refute Info.deny_fields_by_default?(SensitiveRecord)
    end

    test "a 4-part grant reads the row but every field is forbidden except the primary key" do
      record = record!()
      result = read_one!(DenyFieldsRecord, record.id, ["denyfieldsrecord:*:read:always"])

      assert result.id == record.id

      for field <- [:name, :department, :phone, :salary, :notes] do
        assert forbidden?(Map.get(result, field)), "#{field} should be forbidden"
      end
    end

    test "a 5-part grant shows its group and the groups it inherits, nothing else" do
      record = record!()

      result =
        read_one!(DenyFieldsRecord, record.id, ["denyfieldsrecord:*:read:always:sensitive"])

      assert result.name == "Ada"
      assert result.department == "Eng"
      assert result.phone == "********"
      assert forbidden?(result.salary)
      assert forbidden?(result.notes)
    end

    test "a 4-part grant beside a 5-part grant adds no field" do
      record = record!()

      result =
        read_one!(DenyFieldsRecord, record.id, [
          "denyfieldsrecord:*:read:always",
          "denyfieldsrecord:*:read:always:public"
        ])

      assert result.name == "Ada"
      assert forbidden?(result.phone)
      assert forbidden?(result.notes)
    end

    test "an ungrouped field stays forbidden with a grant for every group" do
      record = record!()

      result =
        read_one!(DenyFieldsRecord, record.id, [
          "denyfieldsrecord:*:read:always:public",
          "denyfieldsrecord:*:read:always:sensitive",
          "denyfieldsrecord:*:read:always:confidential"
        ])

      assert result.salary == 100
      assert result.phone == "555-1234"
      assert forbidden?(result.notes)
    end

    test "a masked group's field is forbidden, not masked, under a 4-part grant" do
      record = record!()
      result = read_one!(DenyFieldsRecord, record.id, ["denyfieldsrecord:*:read:always"])

      assert forbidden?(result.phone)
    end

    test "field_group :all, except: works" do
      record = create!(DenyFieldsExceptRecord, %{name: "Ada", email: "a@x", salary: 100})

      row_only =
        read_one!(DenyFieldsExceptRecord, record.id, ["denyfieldsexceptrecord:*:read:always"])

      assert forbidden?(row_only.name)
      assert forbidden?(row_only.email)
      assert forbidden?(row_only.salary)

      public =
        read_one!(DenyFieldsExceptRecord, record.id, [
          "denyfieldsexceptrecord:*:read:always:public"
        ])

      assert public.name == "Ada"
      assert public.email == "a@x"
      assert forbidden?(public.salary)

      full =
        read_one!(DenyFieldsExceptRecord, record.id, ["denyfieldsexceptrecord:*:read:always:full"])

      assert full.salary == 100
    end

    test "the ungrouped policy names only ungrouped fields" do
      ungrouped =
        DenyFieldsRecord
        |> Ash.Policy.Info.field_policies()
        |> Enum.filter(fn policy ->
          Enum.any?(policy.policies, &(&1.check_module == AshGrant.UngroupedFieldCheck))
        end)

      assert [%{fields: [:notes]}] = ungrouped
    end

    test "a resource whose fields are all grouped gets no ungrouped policy" do
      refute DenyFieldsExceptRecord
             |> Ash.Policy.Info.field_policies()
             |> Enum.flat_map(& &1.policies)
             |> Enum.any?(&(&1.check_module == AshGrant.UngroupedFieldCheck))
    end
  end

  describe "flag off" do
    test "an ungrouped field stays visible with a 5-part grant" do
      record = create!(DenyFieldsOptOutRecord, %{name: "Ada", notes: "n"})

      result =
        read_one!(DenyFieldsOptOutRecord, record.id, [
          "denyfieldsoptoutrecord:*:read:always:public"
        ])

      assert result.name == "Ada"
      assert result.notes == "n"
    end

    test "a 4-part grant shows every field" do
      record = create!(DenyFieldsOptOutRecord, %{name: "Ada", notes: "n"})

      result =
        read_one!(DenyFieldsOptOutRecord, record.id, ["denyfieldsoptoutrecord:*:read:always"])

      assert result.name == "Ada"
      assert result.notes == "n"
    end
  end

  describe "domain-level flag" do
    test "reaches a resource that does not set it" do
      assert Info.deny_fields_by_default?(DenyFieldsDomainRecord)

      record = create!(DenyFieldsDomainRecord, %{name: "Ada", notes: "n"})

      row_only =
        read_one!(DenyFieldsDomainRecord, record.id, ["denyfieldsdomainrecord:*:read:always"])

      assert row_only.id == record.id
      assert forbidden?(row_only.name)
      assert forbidden?(row_only.notes)

      public =
        read_one!(DenyFieldsDomainRecord, record.id, [
          "denyfieldsdomainrecord:*:read:always:public"
        ])

      assert public.name == "Ada"
      assert forbidden?(public.notes)
    end

    test "a resource's false overrides the domain's true" do
      refute Info.deny_fields_by_default?(DenyFieldsOptOutRecord)
    end
  end

  describe "resolve_deny_fields_by_default/3" do
    test "the first set value wins, resource before domain before app config" do
      assert Info.resolve_deny_fields_by_default(nil, nil, nil) == false
      assert Info.resolve_deny_fields_by_default(nil, nil, true) == true
      assert Info.resolve_deny_fields_by_default(nil, false, true) == false
      assert Info.resolve_deny_fields_by_default(nil, true, false) == true
      assert Info.resolve_deny_fields_by_default(false, true, true) == false
      assert Info.resolve_deny_fields_by_default(true, false, false) == true
    end

    test "a non-boolean app config value raises" do
      assert_raise ArgumentError, ~r/config :ash_grant, :deny_fields_by_default.*"true"/, fn ->
        Info.resolve_deny_fields_by_default(nil, nil, "true")
      end
    end
  end

  describe "Evaluator" do
    test "get_all_field_groups drops group-less grants under the flag" do
      perms = ["r:*:read:always", "r:*:read:always:public"]

      assert Evaluator.get_all_field_groups(perms, "r", "read", :read) == []

      assert Evaluator.get_all_field_groups(perms, "r", "read", :read,
               deny_fields_by_default: true
             ) == ["public"]

      assert Evaluator.get_all_field_groups(["r:*:read:always"], "r", "read", :read,
               deny_fields_by_default: true
             ) == []
    end

    test "field_group_grants counts a group-less grant toward no group under the flag" do
      perms = ["denyfieldsrecord:*:read:always"]

      assert Evaluator.field_group_grants(perms, DenyFieldsRecord, "read", :public, :read) == []

      assert [_] =
               Evaluator.field_group_grants(perms, DenyFieldsRecord, "read", :public, :read,
                 deny_fields_by_default: false
               )
    end
  end

  describe "Introspect" do
    test "can?/4 allows the row and reports only the 5-part groups" do
      assert {:allow, %{field_groups: []}} =
               Introspect.can?(DenyFieldsRecord, :read, %{
                 permissions: ["denyfieldsrecord:*:read:always"]
               })

      assert {:allow, %{field_groups: ["public"]}} =
               Introspect.can?(DenyFieldsRecord, :read, %{
                 permissions: [
                   "denyfieldsrecord:*:read:always",
                   "denyfieldsrecord:*:read:always:public"
                 ]
               })
    end

    test "actor_permissions reports only the 5-part groups" do
      actor = %{
        permissions: ["denyfieldsrecord:*:read:always", "denyfieldsrecord:*:read:always:public"]
      }

      read =
        Enum.find(Introspect.actor_permissions(DenyFieldsRecord, actor), &(&1.action == "read"))

      assert read.allowed
      assert read.field_groups == ["public"]
    end

    test "intersect_field_groups reads [] as no group under the flag" do
      assert Introspect.intersect_field_groups(DenyFieldsRecord, [], ["public"]) == []
      assert Introspect.intersect_field_groups(DenyFieldsRecord, ["public"], []) == []
      assert Introspect.intersect_field_groups(SensitiveRecord, [], ["public"]) == ["public"]
    end

    test "intersect_field_groups reports no group for disjoint lists under the flag" do
      assert Introspect.intersect_field_groups(DenyFieldsDisjointRecord, ["a"], ["b"]) == []
    end
  end

  describe "policy tester" do
    alias AshGrant.PolicyTest.Assertions

    test "a 4-part grant shows no field" do
      assert :ok ==
               Assertions.do_assert_fields_hidden(PolicyTest, :row_only, :read, [:name, :notes])

      assert_raise AshGrant.PolicyTest.AssertionError, fn ->
        Assertions.do_assert_fields_visible(PolicyTest, :row_only, :read, [:name])
      end
    end

    test "a 5-part grant shows its group and inherited groups only" do
      assert :ok ==
               Assertions.do_assert_fields_visible(PolicyTest, :sensitive, :read, [
                 :name,
                 :department,
                 :phone
               ])

      assert :ok ==
               Assertions.do_assert_fields_hidden(PolicyTest, :sensitive, :read, [:salary, :notes])
    end

    test "assert_can still passes for the row" do
      assert :ok == Assertions.do_assert_can(PolicyTest, :row_only, :read, nil)
    end
  end

  describe "masking" do
    test "an instance grant's masked group masks the field on that record only" do
      granted = record!()
      other = record!()

      perms = [
        "denyfieldsrecord:*:read:always",
        "denyfieldsrecord:#{granted.id}:read::sensitive"
      ]

      results = Ash.read!(DenyFieldsRecord, actor: %{permissions: perms})

      assert Enum.find(results, &(&1.id == granted.id)).phone == "********"
      assert forbidden?(Enum.find(results, &(&1.id == other.id)).phone)
    end

    test "a 4-part grant beside a 5-part masked grant still masks under the flag" do
      record = record!()

      result =
        read_one!(DenyFieldsRecord, record.id, [
          "denyfieldsrecord:*:read:always",
          "denyfieldsrecord:*:read:always:sensitive"
        ])

      assert result.phone == "********"
    end
  end

  describe "FieldCheck" do
    test "a 4-part grant fails a group field under the flag" do
      authorizer = %{
        resource: DenyFieldsRecord,
        action: %{name: :read, type: :read},
        query: %{tenant: nil},
        changeset: nil
      }

      refute AshGrant.FieldCheck.match?(
               %{permissions: ["denyfieldsrecord:*:read:always"]},
               authorizer,
               field_group: :public
             )
    end
  end

  describe "app config" do
    setup do
      previous = Application.fetch_env(:ash_grant, :deny_fields_by_default)
      Application.put_env(:ash_grant, :deny_fields_by_default, true)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ash_grant, :deny_fields_by_default, value)
          :error -> Application.delete_env(:ash_grant, :deny_fields_by_default)
        end
      end)
    end

    test "turns the flag on for a resource that sets it nowhere" do
      record = create!(DenyFieldsAppConfigRecord, %{name: "Ada", notes: "n"})

      result =
        read_one!(DenyFieldsAppConfigRecord, record.id, [
          "denyfieldsappconfigrecord:*:read:always"
        ])

      assert result.id == record.id
      assert forbidden?(result.name)
      assert forbidden?(result.notes)
    end
  end

  describe "without default_field_policies" do
    test "a resource-level true is a compile error" do
      assert_raise Spark.Error.DslError,
                   ~r/no effect without\n?\s*`default_field_policies true`/,
                   fn ->
                     defmodule NoFieldPoliciesStrict do
                       @moduledoc false
                       use Ash.Resource,
                         domain: nil,
                         validate_domain_inclusion?: false,
                         data_layer: Ash.DataLayer.Ets,
                         extensions: [AshGrant]

                       ash_grant do
                         resolver(fn _, _ -> [] end)
                         deny_fields_by_default(true)
                         scope(:always, true)
                         field_group(:public, [:name])
                       end

                       attributes do
                         uuid_primary_key(:id)
                         attribute(:name, :string, public?: true)
                       end

                       actions do
                         defaults([:read])
                       end
                     end
                   end
    end

    test "the verifier reports an inherited true" do
      output =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshGrant.DenyFieldsByDefaultTest.FlagDomain3 do
            @moduledoc false
            use Ash.Domain,
              extensions: [AshGrant.Domain],
              validate_config_inclusion?: false

            ash_grant do
              deny_fields_by_default(true)
            end

            resources do
              allow_unregistered?(true)
            end
          end

          defmodule AshGrant.DenyFieldsByDefaultTest.DomainNoFieldPolicies do
            @moduledoc false
            use Ash.Resource,
              domain: AshGrant.DenyFieldsByDefaultTest.FlagDomain3,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshGrant]

            ash_grant do
              resolver(fn _, _ -> [] end)
              scope(:always, true)
              field_group(:public, [:name])
            end

            attributes do
              uuid_primary_key(:id)
              attribute(:name, :string, public?: true)
            end

            actions do
              defaults([:read])
            end
          end
          """)
        end)

      assert output =~ "has no effect without"
      refute Info.deny_fields_by_default?(AshGrant.DenyFieldsByDefaultTest.DomainNoFieldPolicies)
    end
  end

  describe "verification" do
    test "a resource-level true without field groups is a compile error" do
      assert_raise Spark.Error.DslError, ~r/deny_fields_by_default is on/, fn ->
        defmodule NoGroupsResource do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            default_field_policies(true)
            deny_fields_by_default(true)
            scope(:always, true)
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end

    test "a domain-level true reaching a resource without field groups is reported" do
      output =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshGrant.DenyFieldsByDefaultTest.FlagDomain do
            @moduledoc false
            use Ash.Domain,
              extensions: [AshGrant.Domain],
              validate_config_inclusion?: false

            ash_grant do
              deny_fields_by_default(true)
            end

            resources do
              allow_unregistered?(true)
            end
          end

          defmodule AshGrant.DenyFieldsByDefaultTest.DomainNoGroups do
            @moduledoc false
            use Ash.Resource,
              domain: AshGrant.DenyFieldsByDefaultTest.FlagDomain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshGrant]

            ash_grant do
              resolver(fn _, _ -> [] end)
              default_field_policies(true)
              scope(:always, true)
            end

            attributes do
              uuid_primary_key(:id)
              attribute(:name, :string, public?: true)
            end

            actions do
              defaults([:read])
            end
          end
          """)
        end)

      assert output =~ "deny_fields_by_default is on",
             "expected a compile warning; output was: #{output}"
    end

    test "a resource-level false silences the domain's true" do
      output =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshGrant.DenyFieldsByDefaultTest.FlagDomain2 do
            @moduledoc false
            use Ash.Domain,
              extensions: [AshGrant.Domain],
              validate_config_inclusion?: false

            ash_grant do
              deny_fields_by_default(true)
            end

            resources do
              allow_unregistered?(true)
            end
          end

          defmodule AshGrant.DenyFieldsByDefaultTest.DomainOptOut do
            @moduledoc false
            use Ash.Resource,
              domain: AshGrant.DenyFieldsByDefaultTest.FlagDomain2,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshGrant]

            ash_grant do
              resolver(fn _, _ -> [] end)
              deny_fields_by_default(false)
              scope(:always, true)
            end

            attributes do
              uuid_primary_key(:id)
              attribute(:name, :string, public?: true)
            end

            actions do
              defaults([:read])
            end
          end
          """)
        end)

      refute output =~ "deny_fields_by_default is on"
    end
  end

  describe "default_field_policies app config" do
    setup do
      keys = [:default_field_policies, :deny_fields_by_default]
      previous = Map.new(keys, &{&1, Application.fetch_env(:ash_grant, &1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:ash_grant, key, value)
          {key, :error} -> Application.delete_env(:ash_grant, key)
        end)
      end)
    end

    defp compile_app_config_resource!(name, ash_grant_body) do
      module = Module.concat([__MODULE__, name])
      domain = Module.concat([__MODULE__, name, Domain])

      Code.compile_string("""
      defmodule #{inspect(domain)} do
        @moduledoc false
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          allow_unregistered?(true)
        end
      end

      defmodule #{inspect(module)} do
        @moduledoc false
        use Ash.Resource,
          domain: #{inspect(domain)},
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshGrant]

        ash_grant do
          resolver(fn actor, _ -> actor.permissions end)
          default_policies(true)
          scope(:always, true)
          #{ash_grant_body}
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, public?: true)
          attribute(:notes, :string, public?: true)
        end

        actions do
          defaults([:read, create: [:name, :notes]])
        end
      end
      """)

      module
    end

    defp read_app_config_record!(module, permissions) do
      record = create!(module, %{name: "Ada", notes: "n"})
      result = read_one!(module, record.id, permissions)
      {record, result}
    end

    test "app true generates field policies for a resource that sets nothing" do
      Application.put_env(:ash_grant, :default_field_policies, true)
      module = compile_app_config_resource!(AppFp, "field_group(:public, [:name])")

      assert Info.default_field_policies(module)
      assert Ash.Policy.Info.field_policies(module) != []
    end

    test "resource false overrides app true" do
      Application.put_env(:ash_grant, :default_field_policies, true)

      module =
        compile_app_config_resource!(AppFpOptOut, """
        default_field_policies(false)
        field_group(:public, [:name])
        """)

      refute Info.default_field_policies(module)
      assert Ash.Policy.Info.field_policies(module) == []
    end

    test "app true with app deny_fields_by_default hides ungranted fields" do
      Application.put_env(:ash_grant, :default_field_policies, true)
      Application.put_env(:ash_grant, :deny_fields_by_default, true)
      module = compile_app_config_resource!(AppFpDeny, "field_group(:public, [:name])")

      {record, result} =
        read_app_config_record!(module, ["#{Info.resource_name(module)}:*:read:always"])

      assert result.id == record.id
      assert forbidden?(result.name)
      assert forbidden?(result.notes)
    end

    test "a non-boolean app value raises" do
      Application.put_env(:ash_grant, :default_field_policies, "yes")

      assert_raise ArgumentError, fn -> Info.resolve_default_field_policies(nil, "yes") end

      # Spark wraps a transformer's ArgumentError in a RuntimeError.
      assert_raise RuntimeError, ~r/default_field_policies must be a boolean/, fn ->
        compile_app_config_resource!(AppFpBad, "field_group(:public, [:name])")
      end
    end

    test "app true leaves a resource without field groups fully visible" do
      Application.put_env(:ash_grant, :default_field_policies, true)
      module = compile_app_config_resource!(AppFpNoGroups, "")

      assert Ash.Policy.Info.field_policies(module) == []

      {record, result} =
        read_app_config_record!(module, ["#{Info.resource_name(module)}:*:read:always"])

      assert result.id == record.id
      assert result.name == "Ada"
      assert result.notes == "n"
    end

    test "app true with deny on reports a resource without field groups" do
      Application.put_env(:ash_grant, :default_field_policies, true)
      Application.put_env(:ash_grant, :deny_fields_by_default, true)

      output =
        capture_io(:stderr, fn -> compile_app_config_resource!(AppFpDenyNoGroups, "") end)

      assert output =~ "defines no field_group"
    end
  end
end

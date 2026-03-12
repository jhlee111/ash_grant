defmodule AshGrant.FieldGroupExceptTest do
  @moduledoc """
  Tests for the field_group `except` (blacklist) option.

  Covers:
  - :all resolves to all resource attributes
  - :all with except excludes specified fields
  - Child group inheriting from except parent and adding back excluded fields
  - except without :all raises compile error
  - mask field in except raises compile error
  - except field not in resource attributes raises compile error
  - Integration: actor with public permission can't see excepted fields
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.ExceptRecord

  describe ":all wildcard resolution" do
    test "ExceptRecord compiles with :all and except option" do
      assert Code.ensure_loaded?(ExceptRecord)
    end

    test ":all with except resolves to all attributes minus excepted fields" do
      fg = AshGrant.Info.get_field_group(ExceptRecord, :public)

      assert fg != nil
      # Should include all attrs except :salary and :ssn
      assert :name in fg.fields
      assert :department in fg.fields
      assert :position in fg.fields
      assert :email in fg.fields
      assert :phone in fg.fields
      assert :address in fg.fields

      # Should NOT include excepted fields
      refute :salary in fg.fields
      refute :ssn in fg.fields
    end

    test "except is preserved on the resolved field group" do
      fg = AshGrant.Info.get_field_group(ExceptRecord, :public)
      assert fg.except == [:salary, :ssn]
    end

    test "child group adding back excepted fields works" do
      fg = AshGrant.Info.get_field_group(ExceptRecord, :full)

      assert fg.inherits == [:public]
      assert fg.fields == [:salary, :ssn]

      # Resolve all fields via resolve_field_group
      %{fields: resolved_fields} = AshGrant.Info.resolve_field_group(ExceptRecord, :full)

      # Should include all fields (parent's resolved + own)
      assert :name in resolved_fields
      assert :department in resolved_fields
      assert :phone in resolved_fields
      assert :salary in resolved_fields
      assert :ssn in resolved_fields
    end

    test "id attribute is included in :all resolution" do
      fg = AshGrant.Info.get_field_group(ExceptRecord, :public)
      assert :id in fg.fields
    end
  end

  describe "compile-time validation errors" do
    test "except without :all raises compile error" do
      assert_raise Spark.Error.DslError, ~r/only valid when/, fn ->
        defmodule ExceptWithoutWildcard do
          use Ash.Resource,
            domain: AshGrant.Test.Domain,
            data_layer: Ash.DataLayer.Ets,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            default_policies(true)
            default_field_policies(true)
            resource_name("exc_no_wildcard")
            scope(:all, true)

            field_group(:bad, [:name, :email], except: [:salary])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
            attribute(:email, :string, public?: true)
            attribute(:salary, :integer, public?: true)
          end

          actions do
            defaults([:read, create: :*])
          end
        end
      end
    end

    test "except field not in resource attributes raises compile error" do
      assert_raise Spark.Error.DslError, ~r/not resource attributes/, fn ->
        defmodule ExceptBadField do
          use Ash.Resource,
            domain: AshGrant.Test.Domain,
            data_layer: Ash.DataLayer.Ets,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            default_policies(true)
            default_field_policies(true)
            resource_name("exc_bad_field")
            scope(:all, true)

            field_group(:bad, :all, except: [:nonexistent_field])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
          end

          actions do
            defaults([:read, create: :*])
          end
        end
      end
    end

    test "mask field in except raises compile error" do
      assert_raise Spark.Error.DslError, ~r/masked fields.*also in.*except/i, fn ->
        defmodule MaskInExcept do
          use Ash.Resource,
            domain: AshGrant.Test.Domain,
            data_layer: Ash.DataLayer.Ets,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            default_policies(true)
            default_field_policies(true)
            resource_name("exc_mask_conflict")
            scope(:all, true)

            field_group(:bad, :all,
              except: [:salary],
              mask: [:salary],
              mask_with: &AshGrant.Test.MaskHelpers.mask_string/2
            )
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
            attribute(:salary, :integer, public?: true)
          end

          actions do
            defaults([:read, create: :*])
          end
        end
      end
    end
  end

  describe ":all without except" do
    test ":all without except resolves to all attributes" do
      defmodule AllNoExcept do
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
          resource_name("all_no_except")
          scope(:all, true)

          field_group(:everything, :all)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, public?: true)
          attribute(:email, :string, public?: true)
          attribute(:salary, :integer, public?: true)
        end

        actions do
          defaults([:read, create: :*])
        end
      end

      fg = AshGrant.Info.get_field_group(AllNoExcept, :everything)
      assert :id in fg.fields
      assert :name in fg.fields
      assert :email in fg.fields
      assert :salary in fg.fields
    end
  end

  describe "integration: field visibility with except" do
    setup do
      record =
        ExceptRecord
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Alice",
            department: "Engineering",
            position: "Staff",
            email: "alice@example.com",
            phone: "555-0100",
            address: "789 Elm St",
            salary: 120_000,
            ssn: "123-45-6789"
          },
          authorize?: false
        )
        |> Ash.create!()

      %{record: record}
    end

    test "actor with :public sees non-excepted fields, not excepted ones", %{record: record} do
      actor = %{permissions: ["exceptrecord:*:read:all:public"]}
      results = ExceptRecord |> Ash.read!(actor: actor)
      result = Enum.find(results, &(&1.id == record.id))

      assert result != nil

      # Non-excepted fields visible
      assert result.name == "Alice"
      assert result.department == "Engineering"
      assert result.position == "Staff"
      assert result.email == "alice@example.com"
      assert result.phone == "555-0100"
      assert result.address == "789 Elm St"

      # Excepted fields forbidden
      assert match?(%Ash.ForbiddenField{}, result.salary)
      assert match?(%Ash.ForbiddenField{}, result.ssn)
    end

    test "actor with 4-part permission (no field_group) sees all fields", %{record: record} do
      actor = %{permissions: ["exceptrecord:*:read:all"]}
      results = ExceptRecord |> Ash.read!(actor: actor)
      result = Enum.find(results, &(&1.id == record.id))

      assert result != nil
      assert result.salary == 120_000
      assert result.ssn == "123-45-6789"
    end

    test "actor with :full sees all fields including excepted ones", %{record: record} do
      actor = %{permissions: ["exceptrecord:*:read:all:full"]}
      results = ExceptRecord |> Ash.read!(actor: actor)
      result = Enum.find(results, &(&1.id == record.id))

      assert result != nil

      # All fields visible
      assert result.name == "Alice"
      assert result.email == "alice@example.com"
      assert result.phone == "555-0100"
      assert result.salary == 120_000
      assert result.ssn == "123-45-6789"
    end
  end
end

defmodule AshGrant.FieldGroupNewDslTest do
  @moduledoc """
  TDD tests for the redesigned field_group DSL (issue #40).

  New syntax:
  - `field_group :name, :all` — all fields (replaces `[:*]`)
  - `field_group :name, :all, except: [...]` — blacklist
  - `field_group :name, [:fields], inherits: [:parents]` — keyword-only inherits
  - Deprecated: `[:*]` still works but emits IO.warn

  These tests are written BEFORE implementation changes (TDD).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 2]

  # ============================================
  # New :all syntax
  # ============================================

  describe "field_group :name, :all (new syntax)" do
    test ":all resolves to all resource attributes" do
      defmodule AllFieldsResource do
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
          resource_name("all_fields_res")
          scope(:always, true)

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

      fg = AshGrant.Info.get_field_group(AllFieldsResource, :everything)
      assert :id in fg.fields
      assert :name in fg.fields
      assert :email in fg.fields
      assert :salary in fg.fields
    end

    test ":all with except resolves to all attributes minus excepted fields" do
      defmodule AllExceptResource do
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
          resource_name("all_except_res")
          scope(:always, true)

          field_group(:public, :all, except: [:salary, :ssn])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, public?: true)
          attribute(:email, :string, public?: true)
          attribute(:salary, :integer, public?: true)
          attribute(:ssn, :string, public?: true)
        end

        actions do
          defaults([:read, create: :*])
        end
      end

      fg = AshGrant.Info.get_field_group(AllExceptResource, :public)
      assert :id in fg.fields
      assert :name in fg.fields
      assert :email in fg.fields
      refute :salary in fg.fields
      refute :ssn in fg.fields
      assert fg.except == [:salary, :ssn]
    end

    test "except without :all raises compile error" do
      assert_raise Spark.Error.DslError, ~r/only valid when/, fn ->
        defmodule ExceptWithoutAll do
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
            resource_name("except_no_all")
            scope(:always, true)

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
  end

  # ============================================
  # New inherits: keyword syntax
  # ============================================

  describe "inherits: keyword option (new syntax)" do
    test "field_group with inherits: keyword sets inherits correctly" do
      defmodule InheritsKeywordResource do
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
          resource_name("inherits_kw_res")
          scope(:always, true)

          field_group(:public, [:name, :department])
          field_group(:sensitive, [:phone, :address], inherits: [:public])
          field_group(:confidential, [:salary, :email], inherits: [:sensitive])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, public?: true)
          attribute(:department, :string, public?: true)
          attribute(:phone, :string, public?: true)
          attribute(:address, :string, public?: true)
          attribute(:salary, :integer, public?: true)
          attribute(:email, :string, public?: true)
        end

        actions do
          defaults([:read, create: :*])
        end
      end

      public = AshGrant.Info.get_field_group(InheritsKeywordResource, :public)
      assert public.inherits == nil
      assert public.fields == [:name, :department]

      sensitive = AshGrant.Info.get_field_group(InheritsKeywordResource, :sensitive)
      assert sensitive.inherits == [:public]
      assert sensitive.fields == [:phone, :address]

      confidential = AshGrant.Info.get_field_group(InheritsKeywordResource, :confidential)
      assert confidential.inherits == [:sensitive]
      assert confidential.fields == [:salary, :email]

      # Verify inheritance resolution
      resolved = AshGrant.Info.resolve_field_group(InheritsKeywordResource, :confidential)
      assert :name in resolved.fields
      assert :department in resolved.fields
      assert :phone in resolved.fields
      assert :address in resolved.fields
      assert :salary in resolved.fields
      assert :email in resolved.fields
    end

    test "inherits: with :all and except works" do
      defmodule InheritsAllExceptResource do
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
          resource_name("inherits_all_except_res")
          scope(:always, true)

          field_group(:base, [:name])
          field_group(:editor, :all, except: [:admin_notes], inherits: [:base])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, public?: true)
          attribute(:email, :string, public?: true)
          attribute(:admin_notes, :string, public?: true)
        end

        actions do
          defaults([:read, create: :*])
        end
      end

      fg = AshGrant.Info.get_field_group(InheritsAllExceptResource, :editor)
      assert fg.inherits == [:base]
      assert :id in fg.fields
      assert :name in fg.fields
      assert :email in fg.fields
      refute :admin_notes in fg.fields
    end
  end

  # ============================================
  # Deprecation: [:*] still works with warning
  # ============================================

  describe "[:*] deprecation" do
    test "[:*] still works but emits deprecation warning" do
      {result, warning} =
        with_io(:stderr, fn ->
          defmodule DeprecatedWildcardResource do
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
              resource_name("deprecated_wildcard_res")
              scope(:always, true)

              field_group(:everything, [:*])
            end

            attributes do
              uuid_primary_key(:id)
              attribute(:name, :string, public?: true)
              attribute(:email, :string, public?: true)
            end

            actions do
              defaults([:read, create: :*])
            end
          end

          AshGrant.Info.get_field_group(DeprecatedWildcardResource, :everything)
        end)

      assert warning =~ "deprecated"
      assert warning =~ ":always"

      # Still resolves correctly
      assert :id in result.fields
      assert :name in result.fields
      assert :email in result.fields
    end

    test "[:*] with except still works but emits deprecation warning" do
      {result, warning} =
        with_io(:stderr, fn ->
          defmodule DeprecatedWildcardExceptResource do
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
              resource_name("deprecated_wc_except_res")
              scope(:always, true)

              field_group(:public, [:*], except: [:salary])
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

          AshGrant.Info.get_field_group(DeprecatedWildcardExceptResource, :public)
        end)

      assert warning =~ "deprecated"
      assert warning =~ ":always"

      assert :name in result.fields
      refute :salary in result.fields
    end
  end

  # ============================================
  # FieldGroup struct type
  # ============================================

  describe "FieldGroup struct with :always" do
    test "fields can be :all atom before transformer resolution" do
      fg = %AshGrant.Dsl.FieldGroup{
        name: :everything,
        fields: :all
      }

      assert fg.fields == :all
    end
  end
end

defmodule AshGrant.PolicyAuthorizerValidationTest do
  @moduledoc """
  Compile-time validation that a resource generating AshGrant policies also
  uses `Ash.Policy.Authorizer`. Without it the generated policies never run and
  every actor reads every row.
  """
  use ExUnit.Case, async: true

  test "rejects default_policies without Ash.Policy.Authorizer" do
    defn = fn ->
      defmodule DefaultPoliciesNoAuthorizer do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          default_policies(true)
          scope(:always, true)
        end

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          defaults([:read])
        end
      end
    end

    assert_raise Spark.Error.DslError,
                 ~r/sets `default_policies` but does not use Ash.Policy.Authorizer/,
                 fn -> defn.() end
  end

  test "rejects default_field_policies without Ash.Policy.Authorizer" do
    defn = fn ->
      defmodule DefaultFieldPoliciesNoAuthorizer do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          default_field_policies(true)
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

    assert_raise Spark.Error.DslError,
                 ~r/sets `default_field_policies` but does not use Ash.Policy.Authorizer/,
                 fn -> defn.() end
  end

  test "accepts default_policies with Ash.Policy.Authorizer" do
    defmodule DefaultPoliciesWithAuthorizer do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshGrant],
        authorizers: [Ash.Policy.Authorizer]

      ash_grant do
        resolver(fn _, _ -> [] end)
        default_policies(true)
        scope(:always, true)
      end

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end
    end

    assert AshGrant.Info.default_policies(DefaultPoliciesWithAuthorizer) == true
  end

  test "accepts a resource without generated policies and without an authorizer" do
    defmodule NoGeneratedPoliciesNoAuthorizer do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshGrant]

      ash_grant do
        resolver(fn _, _ -> [] end)
        scope(:always, true)
      end

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end
    end

    assert AshGrant.Info.default_policies(NoGeneratedPoliciesNoAuthorizer) == false
  end
end

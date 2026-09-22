defmodule AshGrant.ScopeThroughValidationTest do
  @moduledoc """
  Compile-time validation tests for the `scope_through` DSL entity.

  Each test defines a deliberately invalid resource inside a `fn -> ... end`
  and asserts that loading it raises a `Spark.Error.DslError` with a helpful
  message. The resources are wrapped so they are only evaluated when the test
  calls the function — this way a failed expectation surfaces as a regular
  assertion failure rather than breaking test loading.
  """
  use ExUnit.Case, async: true

  test "rejects a scope_through that references a has_many relationship" do
    defn = fn ->
      defmodule ScopeThroughChild do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets

        attributes do
          uuid_primary_key(:id)
          attribute(:parent_id, :uuid, allow_nil?: true)
        end

        actions do
          defaults([:read])
        end
      end

      defmodule ScopeThroughHasManyParent do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          scope(:always, true)
          scope_through(:children)
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          has_many :children, ScopeThroughChild do
            destination_attribute(:parent_id)
          end
        end

        actions do
          defaults([:read])
        end
      end
    end

    assert_raise Spark.Error.DslError, ~r/is a :has_many relationship/, fn -> defn.() end
  end
end

defmodule AshGrant.ResolveArgumentValidationTest do
  @moduledoc """
  Compile-time validation tests for the `resolve_argument` DSL sugar.

  Each test defines a deliberately invalid resource inside a `fn -> ... end`
  and asserts that loading it raises a `Spark.Error.DslError` with a helpful
  message. The resources are wrapped so they are only evaluated when the test
  calls the function — this way a failed expectation surfaces as a regular
  assertion failure rather than breaking test loading.
  """
  use ExUnit.Case, async: true

  test "rejects :from_path that starts with a non-existent relationship" do
    defn = fn ->
      defmodule BadPathMissingRel do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          scope(:has_ref, expr(^arg(:center_id) == ^actor(:org_id)))
          resolve_argument(:center_id, from_path: [:nonexistent_rel, :center_id])
        end

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end
    end

    assert_raise Spark.Error.DslError, ~r/has no[\s\S]*relationship :nonexistent_rel/, fn ->
      defn.()
    end
  end

  test "rejects :from_path whose leaf is a relationship rather than an attribute" do
    defn = fn ->
      defmodule BadPathLeafIsRel do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          scope(:has_ref, expr(^arg(:parent) == ^actor(:id)))
          resolve_argument(:parent, from_path: [:parent])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:parent_id, :uuid, allow_nil?: true)
        end

        relationships do
          belongs_to(:parent, __MODULE__, define_attribute?: false, source_attribute: :parent_id)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end
    end

    assert_raise Spark.Error.DslError, ~r/ends on a[\s\S]*relationship/, fn -> defn.() end
  end

  test "rejects :from_path whose leaf is neither a relationship nor an attribute" do
    defn = fn ->
      defmodule BadPathLeafMissing do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          scope(:has_ref, expr(^arg(:nothing) == ^actor(:id)))
          resolve_argument(:nothing, from_path: [:nothing_here])
        end

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end
    end

    assert_raise Spark.Error.DslError, ~r/neither a[\s\S]*relationship nor an attribute/, fn ->
      defn.()
    end
  end

  test "rejects resolve_argument that is not referenced by any scope" do
    defn = fn ->
      defmodule DeadResolveArg do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          scope(:own, expr(author_id == ^actor(:id)))
          # No scope references ^arg(:center_id) — this is dead code.
          resolve_argument(:center_id, from_path: [:id])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:author_id, :uuid, allow_nil?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end
    end

    assert_raise Spark.Error.DslError, ~r/no scope references/, fn -> defn.() end
  end

  test "rejects :for_actions that names a non-existent action" do
    defn = fn ->
      defmodule BadForActions do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          scope(:has_ref, expr(^arg(:id) == ^actor(:id)))
          resolve_argument(:id, from_path: [:id], for_actions: [:nonexistent_action])
        end

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end
    end

    assert_raise Spark.Error.DslError, ~r/nonexistent_action/, fn -> defn.() end
  end
end

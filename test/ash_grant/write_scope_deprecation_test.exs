defmodule AshGrant.WriteScopeDeprecationTest do
  @moduledoc """
  Verifies that using the deprecated `write:` option on a scope emits a
  compile-time deprecation warning pointing users at the argument-based
  scope pattern.

  This guards against the deprecation wiring silently regressing if Spark
  changes how `deprecations:` entries are handled, or if the entry is
  removed from `lib/ash_grant/dsl.ex`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "using write: emits a deprecation warning mentioning resolve_argument" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.WriteScopeDeprecationTest.UsesWriteOption do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            scope(:readonly, [], expr(author_id == ^actor(:id)), write: false)
          end

          attributes do
            uuid_primary_key :id
            attribute :author_id, :uuid, allow_nil?: true
          end

          actions do
            defaults [:read]
          end
        end
        """)
      end)

    assert output =~ "write",
           "expected the write key to be flagged as deprecated; output was: #{output}"

    assert output =~ "resolve_argument",
           "expected the deprecation message to point at resolve_argument; output was: #{output}"
  end

  test "a scope without write: produces no deprecation warning" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.WriteScopeDeprecationTest.NoWriteOption do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            resolver fn _, _ -> [] end
            scope :own, expr(author_id == ^actor(:id))
          end

          attributes do
            uuid_primary_key :id
            attribute :author_id, :uuid, allow_nil?: true
          end

          actions do
            defaults [:read]
          end
        end
        """)
      end)

    refute output =~ "write",
           "expected no deprecation warning mentioning write:; output was: #{output}"
  end
end

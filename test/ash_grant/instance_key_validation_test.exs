defmodule AshGrant.InstanceKeyValidationTest do
  @moduledoc """
  Validation tests for the `instance_key` option (#148).

  The default `instance_key` must resolve to the resource's actual primary key
  rather than the hardcoded `:id`, and an explicitly configured key must exist
  as an attribute — including the literal `:id`, which the old validation
  silently skipped.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule NonIdPk do
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
      uuid_primary_key(:uuid)
    end

    actions do
      defaults([:read])
    end
  end

  test "instance_key defaults to the primary key when it is not :id" do
    assert AshGrant.Info.instance_key(NonIdPk) == :uuid
  end

  test "warns when an explicit instance_key names no attribute, even :id" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.InstanceKeyValidationTest.BadInstanceKey do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            scope(:always, true)
            instance_key(:id)
          end

          attributes do
            uuid_primary_key(:uuid)
          end

          actions do
            defaults([:read])
          end
        end
        """)
      end)

    assert output =~ "instance_key :id does not exist as an attribute",
           "expected a compile warning about the invalid instance_key; output was: #{output}"
  end

  test "does not warn about :id for a composite primary key without instance_key" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.InstanceKeyValidationTest.CompositePk do
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
            attribute(:tenant_id, :uuid, primary_key?: true, allow_nil?: false)
            attribute(:user_id, :uuid, primary_key?: true, allow_nil?: false)
          end

          actions do
            defaults([:read])
          end
        end
        """)
      end)

    refute output =~ "instance_key :id does not exist as an attribute",
           "composite primary keys have no single instance_key default; " <>
             "expected no warning, got: #{output}"
  end
end

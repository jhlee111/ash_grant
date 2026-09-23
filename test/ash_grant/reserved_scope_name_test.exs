defmodule AshGrant.ReservedScopeNameTest do
  @moduledoc """
  Verifies that declaring a scope with a reserved universal name
  (`always`/`all`/`global`) and a non-`true` filter emits a compile warning,
  since the checks short-circuit on the name and would silently ignore the
  filter (#139 follow-up).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "warns when a reserved scope name declares a non-true filter" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.ReservedScopeNameTest.RestrictiveGlobal do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            scope(:global, expr(status == :published))
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:status, :atom, allow_nil?: true)
          end

          actions do
            defaults([:read])
          end
        end
        """)
      end)

    assert output =~ "uses a reserved name",
           "expected a reserved-name warning; output was: #{output}"
  end

  test "does not warn for a reserved name with a true filter" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.ReservedScopeNameTest.AlwaysTrue do
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
        """)
      end)

    refute output =~ "uses a reserved name",
           "expected no reserved-name warning; output was: #{output}"
  end
end

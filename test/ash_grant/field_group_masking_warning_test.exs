defmodule AshGrant.FieldGroupMaskingWarningTest do
  @moduledoc """
  Verifies that a `field_group` whose masked fields are claimed by an earlier
  group (dedup) emits a compile-time warning instead of silently losing masking
  (#130).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  def mask(value, _field), do: value

  test "warns when a field_group masks fields owned by an earlier group" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.FieldGroupMaskingWarningTest.DeadMasking do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            default_field_policies(true)

            field_group(:restricted, :all, except: [:name])
            field_group(:pii, [:email], mask: [:email], mask_with: &AshGrant.FieldGroupMaskingWarningTest.mask/2)
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
            attribute(:email, :string, public?: true)
          end

          actions do
            defaults([:read])
          end
        end
        """)
      end)

    assert output =~ "masks [:email]",
           "expected a dead-masking warning; output was: #{output}"
  end

  test "does not warn when the masking group owns its masked fields" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshGrant.FieldGroupMaskingWarningTest.LiveMasking do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            default_field_policies(true)

            field_group(:pii, [:email], mask: [:email], mask_with: &AshGrant.FieldGroupMaskingWarningTest.mask/2)
            field_group(:restricted, :all, except: [:name])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:name, :string, public?: true)
            attribute(:email, :string, public?: true)
          end

          actions do
            defaults([:read])
          end
        end
        """)
      end)

    refute output =~ "masks [:email]",
           "expected no dead-masking warning; output was: #{output}"
  end
end

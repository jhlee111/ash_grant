defmodule AshGrant.Test.MaskHelpers do
  @moduledoc false
  # Masking functions for test resources

  def mask_string(value, _field) when is_binary(value) do
    String.replace(value, ~r/./, "*")
  end

  def mask_string(_value, _field), do: "***"
end

defmodule AshGrant.Test.MaskedRecord do
  @moduledoc """
  Test resource for field masking integration.

  Uses ETS data layer and defines field groups with masking to test
  the masking preparation.

  ## Field Groups

  | Group | Own Fields | Inherits From | Masking |
  |-------|-----------|---------------|---------|
  | :public | name, department | — | none |
  | :sensitive | phone, address | :public | phone, address masked |
  | :confidential | salary, email | :sensitive | none (sees originals) |
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    default_policies(true)
    default_field_policies(true)
    resource_name("maskedrecord")

    scope(:always, true)

    field_group(:public, [:name, :department])

    field_group(:sensitive, [:phone, :address],
      inherits: [:public],
      mask: [:phone, :address],
      mask_with: &AshGrant.Test.MaskHelpers.mask_string/2
    )

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
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

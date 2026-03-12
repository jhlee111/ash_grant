defmodule AshGrant.Test.SensitiveRecord do
  @moduledoc """
  Test resource for field-group column-level authorization.

  Uses ETS data layer (no database needed) and defines three field groups
  with inheritance to test the field_group DSL entity and Info helpers.

  ## Field Groups

  | Group | Own Fields | Inherits From |
  |-------|-----------|---------------|
  | :public | name, department, position | — |
  | :sensitive | phone, address | :public |
  | :confidential | salary, email | :sensitive |
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
    resource_name("sensitiverecord")

    scope(:all, true)

    field_group(:public, [:name, :department, :position])
    field_group(:sensitive, [:phone, :address], inherits: [:public])
    field_group(:confidential, [:salary, :email], inherits: [:sensitive])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:department, :string, public?: true)
    attribute(:position, :string, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:phone, :string, public?: true)
    attribute(:address, :string, public?: true)
    attribute(:salary, :integer, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.OverlappingRecord do
  @moduledoc """
  Test resource for overlapping field_group definitions using `:always`.

  Multiple field groups use `:always` (or `:all, except:`), which expand to
  overlapping attribute lists. Without deduplication, a field would appear
  in multiple field_policies, causing Ash's "all must pass" semantics to
  deny access when only one group's check passes.

  ## Field Groups

  | Group | Definition | Expected Unique Fields |
  |-------|-----------|----------------------|
  | :public | [:name, :description, :price] | name, description, price |
  | :internal | :all, except: [:tax_code], inherits: [:public] | remaining except tax_code |
  | :admin | :all, inherits: [:internal] | tax_code (only remaining) |
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
    resource_name("overlappingrecord")

    scope(:always, true)

    field_group(:public, [:name, :description, :price])
    field_group(:internal, :all, except: [:tax_code], inherits: [:public])
    field_group(:admin, :all, inherits: [:internal])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:price, :integer, public?: true)
    attribute(:cost, :integer, public?: true)
    attribute(:supplier, :string, public?: true)
    attribute(:tax_code, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.TenantOrder do
  @moduledoc """
  Attribute-multitenant Postgres resource used to reproduce the
  `resolve_argument` CREATE-path tenant forwarding bug (issue #99).

  Pairs with `AshGrant.Test.TenantRefund`, which declares
  `resolve_argument :center_id, from_path: [:order, :center_id]` on an action
  whose target (this resource) is attribute-multitenant.
  """

  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("tenant_orders")
    repo(AshGrant.TestRepo)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:center_id, :uuid, public?: true, allow_nil?: false)
    attribute(:tenant_id, :uuid, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:center_id])
    end

    update :update do
      accept([:center_id])
    end
  end
end

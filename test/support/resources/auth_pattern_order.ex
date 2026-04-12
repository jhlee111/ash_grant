defmodule AshGrant.Test.Auth.Order do
  @moduledoc false
  # Test resource for the "argument-based scope + resource-local argument
  # resolution" pattern. Order is the anchor that carries :center_id; Refund
  # (the authorization target) reaches center_id only via its :order relationship.

  use Ash.Resource,
    domain: AshGrant.Test.Auth.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:center_id, :uuid, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

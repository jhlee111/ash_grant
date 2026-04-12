defmodule AshGrant.Test.Auth.Refund do
  @moduledoc false
  # Test resource demonstrating the "argument-based scope + resource-local
  # argument resolution" pattern. Refund has no :center_id directly — it reaches
  # it via order.center_id. Instead of a relational scope like
  #   expr(order.center_id in ^actor(:own_org_unit_ids))
  # we use:
  #   expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
  # and a change module loads order.center_id into the :center_id argument —
  # but only when the actor's permissions actually reference that argument.

  use Ash.Resource,
    domain: AshGrant.Test.Auth.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ets do
    private?(true)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    resource_name("refund")

    scope(:always, true)
    scope(:by_own_author, expr(author_id == ^actor(:id)))
    scope(:at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids)))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true, allow_nil?: false)
    attribute(:amount, :integer, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to :order, AshGrant.Test.Auth.Order do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(AshGrant.filter_check())
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(AshGrant.check())
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:author_id, :amount, :order_id])
    end

    update :update do
      accept([:amount])
      require_atomic?(false)
      # Lazy-load order.center_id into :center_id argument only when a permission
      # in play actually references it. Skips the DB load for scopes like
      # :by_own_author that don't need the relationship.
      argument(:center_id, :uuid, allow_nil?: true)
      change({AshGrant.Test.Auth.ResolveCenterIdFromOrder, []})
    end
  end
end

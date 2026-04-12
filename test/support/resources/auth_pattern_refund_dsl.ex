defmodule AshGrant.Test.Auth.RefundDsl do
  @moduledoc false
  # Same semantic as AshGrant.Test.Auth.Refund, but using the
  # `resolve_argument` DSL sugar instead of a hand-rolled change module.

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

    resource_name("refund_dsl")

    scope(:always, true)
    scope(:by_own_author, expr(author_id == ^actor(:id)))
    scope(:at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids)))

    resolve_argument(:center_id, from_path: [:order, :center_id])
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
    defaults([:read])

    create :create do
      accept([:author_id, :amount, :order_id])
    end

    update :update do
      accept([:amount])
      require_atomic?(false)
    end

    destroy :destroy do
      require_atomic?(false)
    end
  end
end

defmodule AshGrant.Test.Auth.RefundStructActor do
  @moduledoc false
  # Test resource for issue #101: when the actor is a struct with no
  # `:permissions` field (as real production Ash resource actors typically
  # are), `ResolveArgument` must still consult the resource's configured
  # `PermissionResolver` to decide whether to resolve the argument.

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
        nil ->
          []

        %{role: :center_manager} ->
          ["refund_struct_actor:*:create:at_own_unit", "refund_struct_actor:*:update:at_own_unit"]

        %{role: :author} ->
          ["refund_struct_actor:*:update:by_own_author"]

        _ ->
          []
      end
    end)

    resource_name("refund_struct_actor")
    default_policies(true)

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

  actions do
    defaults([:read])

    create :create do
      accept([:author_id, :amount, :order_id])
    end

    update :update do
      accept([:amount])
      require_atomic?(false)
    end
  end
end

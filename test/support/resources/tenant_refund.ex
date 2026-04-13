defmodule AshGrant.Test.TenantRefund do
  @moduledoc """
  Attribute-multitenant Postgres resource used to reproduce the
  `resolve_argument` CREATE-path tenant forwarding bug (issue #99).

  The `resolve_argument` declaration below triggered silent failure prior to
  the fix: on :create, `ResolveArgument` called `Ash.get!` without
  forwarding the changeset's tenant, so the target (a multitenant resource)
  raised, was rescued, and the argument stayed nil — denying the action.
  """

  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("tenant_refunds")
    repo(AshGrant.TestRepo)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    resource_name("tenant_refund")
    default_policies(true)

    scope(:always, true)
    scope(:at_own_unit, expr(^arg(:center_id) in ^actor(:own_center_ids)))

    resolve_argument(:center_id, from_path: [:order, :center_id])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:amount, :integer, public?: true, allow_nil?: false)
    attribute(:tenant_id, :uuid, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to :order, AshGrant.Test.TenantOrder do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:amount, :order_id])
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

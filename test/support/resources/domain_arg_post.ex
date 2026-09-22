defmodule AshGrant.Test.DomainArgPost do
  @moduledoc """
  Resource on `AshGrant.Test.ArgResolverDomain` that inherits the `:at_own_unit`
  scope (which references `^arg(:center_id)`) from the domain and declares
  `resolve_argument` with no local scope referencing the argument (#147).
  """
  use Ash.Resource,
    domain: AshGrant.Test.ArgResolverDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    default_policies(true)

    resolve_argument(:center_id, from_path: [:org_id])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.ResolverOnlyPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.ResolverOnlyDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    default_policies(true)

    scope(:always, true)
    scope(:own, expr(author_id == ^actor(:id)))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:title, :author_id])
    end
  end
end

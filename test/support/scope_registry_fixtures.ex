defmodule AshGrant.Test.GlobalScopes do
  @moduledoc false
  use AshGrant.ScopeRegistry

  scopes do
    scope(:always, true)
    scope(:own, expr(author_id == ^actor(:id)))
    scope(:registry_only, expr(status == :archived))
  end
end

defmodule AshGrant.Test.RegistryDomain do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshGrant.Domain],
    validate_config_inclusion?: false

  ash_grant do
    # Overrides the registry's :own scope
    scope(:own, expr(domain_author_id == ^actor(:id)))
  end

  resources do
    resource(AshGrant.Test.RegistryOnlyPost)
    resource(AshGrant.Test.RegistryDomainOverridePost)
    resource(AshGrant.Test.RegistryResourceOverridePost)
  end
end

defmodule AshGrant.Test.RegistryOnlyPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.RegistryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrant]

  ash_grant do
    resolver(fn _actor, _ctx -> [] end)
  end

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true)
    attribute(:status, :atom, public?: true)
  end
end

defmodule AshGrant.Test.RegistryDomainOverridePost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.RegistryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrant]

  ash_grant do
    resolver(fn _actor, _ctx -> [] end)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true)
    attribute(:domain_author_id, :uuid, public?: true)
  end
end

defmodule AshGrant.Test.RegistryResourceOverridePost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.RegistryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrant]

  ash_grant do
    resolver(fn _actor, _ctx -> [] end)
    scope(:own, expr(resource_author_id == ^actor(:id)))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true)
    attribute(:domain_author_id, :uuid, public?: true)
    attribute(:resource_author_id, :uuid, public?: true)
  end
end

defmodule AshGrant.Test.ResolverFallbackResolver do
  @moduledoc false
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(_actor, _context), do: ["resolver_fallback_post:*:read:always"]
end

defmodule AshGrant.Test.ResolverFallbackDomainResolver do
  @moduledoc false
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(_actor, _context), do: ["resolver_fallback_post:*:read:always"]
end

defmodule AshGrant.Test.ResolverFallbackResourceResolver do
  @moduledoc false
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(_actor, _context), do: ["resolver_fallback_post:*:read:always"]
end

defmodule AshGrant.Test.ResolverFallbackBareDomain do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshGrant.Domain],
    validate_config_inclusion?: false

  resources do
    resource(AshGrant.Test.ResolverFallbackOnlyPost)
    resource(AshGrant.Test.ResolverFallbackResourceOverridePost)
  end
end

defmodule AshGrant.Test.ResolverFallbackDomain do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshGrant.Domain],
    validate_config_inclusion?: false

  ash_grant do
    resolver(AshGrant.Test.ResolverFallbackDomainResolver)
  end

  resources do
    resource(AshGrant.Test.ResolverFallbackDomainOverridePost)
  end
end

defmodule AshGrant.Test.ResolverFallbackOnlyPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.ResolverFallbackBareDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrant]

  ash_grant do
    scope(:always, true)
  end

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true)
  end
end

defmodule AshGrant.Test.ResolverFallbackResourceOverridePost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.ResolverFallbackBareDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrant]

  ash_grant do
    resolver(AshGrant.Test.ResolverFallbackResourceResolver)
    scope(:always, true)
  end

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true)
  end
end

defmodule AshGrant.Test.ResolverFallbackDomainOverridePost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.ResolverFallbackDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrant]

  ash_grant do
    scope(:always, true)
  end

  actions do
    defaults([:read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true)
  end
end

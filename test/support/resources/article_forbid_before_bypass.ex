defmodule AshGrant.Test.ArticleForbidBeforeBypass do
  @moduledoc false
  # A `forbid_if` policy declared above a `bypass`. The generated default
  # policies must not reorder the user's own policies, so the forbid still runs
  # before the bypass can authorize.
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ets do
    private?(true)
  end

  ash_grant do
    resolver(fn _actor, _context -> ["article_forbid_before_bypass:*:create:always"] end)
    resource_name("article_forbid_before_bypass")
    default_policies(true)
    scope(:always, true)
  end

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read, :create])
  end

  policies do
    policy action_type(:create) do
      forbid_if(always())
    end

    bypass always() do
      authorize_if(always())
    end
  end
end

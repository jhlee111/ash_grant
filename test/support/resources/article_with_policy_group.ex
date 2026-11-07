defmodule AshGrant.Test.ArticleWithPolicyGroup do
  @moduledoc false
  # `default_policies true` alongside a `policy_group`, whose struct has no
  # `bypass?` key.
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ets do
    private?(true)
  end

  ash_grant do
    resolver(fn _actor, _context -> ["article_with_policy_group:*:create:always"] end)
    resource_name("article_with_policy_group")
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
    policy_group action_type(:create) do
      policy always() do
        authorize_if(always())
      end
    end
  end
end

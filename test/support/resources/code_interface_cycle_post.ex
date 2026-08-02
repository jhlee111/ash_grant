defmodule AshGrant.Test.CodeInterfaceCyclePost do
  @moduledoc """
  Regression resource used by `AshGrant.CodeInterfaceCycleTest`.

  Pairs with `AshGrant.Test.CodeInterfaceCycleDomain`, which has both the
  `AshGrant.Domain` extension (providing resolver + scopes) and a
  domain-level `code_interface do define ... end` block referencing this
  resource. Before the fix, compiling this pair deadlocked: the resource's
  `MergeDomainConfig` transformer forced the domain to compile while the
  domain's code_interface transformer was waiting for the resource.
  """
  use Ash.Resource,
    domain: AshGrant.Test.CodeInterfaceCycleDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    default_policies(true)
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

    update :update do
      accept([:title])
    end
  end
end

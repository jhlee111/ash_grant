defmodule AshGrant.Test.NoResolverPost do
  @moduledoc """
  Test resource used to exercise the runtime guard in
  `AshGrant.Check.resolve_permissions/3` when neither the resource nor its
  domain declares a resolver.

  Compiling this module produces a compile warning via the
  `AshGrant.Verifiers.ValidateResolverPresent` verifier. That is expected
  and the warning is captured/suppressed by the test that loads this
  module.
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    default_policies(true)
    scope(:always, true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

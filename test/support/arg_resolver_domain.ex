defmodule AshGrant.Test.ArgResolverDomain do
  @moduledoc """
  Domain that combines `AshGrant.Domain` scope inheritance with a
  domain-level `code_interface` entry — the combination that deadlocked under
  the pre-v0.20 transformer-based merge.

  Provides `:at_own_unit`, whose filter references `^arg(:center_id)`. A
  resource on this domain can therefore declare `resolve_argument(:center_id, …)`
  with no local scope referencing the argument (#147).
  """
  use Ash.Domain,
    extensions: [AshGrant.Domain],
    validate_config_inclusion?: false

  ash_grant do
    scope(:always, true)
    scope(:at_own_unit, expr(^arg(:center_id) in ^actor(:org_ids)))
  end

  resources do
    resource AshGrant.Test.DomainArgPost do
      define(:read_domain_arg_post, action: :read)
    end
  end
end

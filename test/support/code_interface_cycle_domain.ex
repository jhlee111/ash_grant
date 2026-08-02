defmodule AshGrant.Test.CodeInterfaceCycleDomain do
  @moduledoc """
  Regression domain that combines `AshGrant.Domain` inheritance with a
  domain-level `code_interface do define … end`.

  This is the scenario that deadlocks on the original transformer-based merge:
  the resource needs the domain compiled (to read ash_grant config) while the
  domain needs the resource compiled (to wire the code_interface). Keeping
  this pair in the test suite guards against regressions to that compile
  cycle.
  """
  use Ash.Domain,
    extensions: [AshGrant.Domain],
    validate_config_inclusion?: false

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    scope(:always, true)
    scope(:own, expr(author_id == ^actor(:id)))
  end

  resources do
    resource AshGrant.Test.CodeInterfaceCyclePost do
      define(:create_code_interface_cycle_post, action: :create)
      define(:read_code_interface_cycle_post, action: :read)
    end
  end
end

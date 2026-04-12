defmodule AshGrant.Test.GrantDomain do
  @moduledoc false
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
    resource(AshGrant.Test.DomainInheritedPost)
    resource(AshGrant.Test.DomainOverridePost)
    resource(AshGrant.Test.DomainMinimalPost)
    resource(AshGrant.Test.DomainCrossInheritPost)
  end
end

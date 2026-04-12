defmodule AshGrant.Test.ScopesOnlyDomain do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshGrant.Domain],
    validate_config_inclusion?: false

  ash_grant do
    scope(:always, true)
    scope(:own, expr(author_id == ^actor(:id)))
    scope(:published, expr(status == :published))
  end

  resources do
    resource(AshGrant.Test.ScopesOnlyPost)
  end
end

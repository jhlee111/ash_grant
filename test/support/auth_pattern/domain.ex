defmodule AshGrant.Test.Auth.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGrant.Test.Auth.Order)
    resource(AshGrant.Test.Auth.Refund)
  end
end

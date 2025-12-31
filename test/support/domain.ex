defmodule AshGrant.Test.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    # Basic resources
    resource AshGrant.Test.Post
    resource AshGrant.Test.Comment

    # Business scenario resources
    resource AshGrant.Test.Document       # Status-based workflow
    resource AshGrant.Test.Employee       # Organization hierarchy
    resource AshGrant.Test.Customer       # Geographic/Territory
    resource AshGrant.Test.Report         # Security classification
    resource AshGrant.Test.Task           # Project/Team
    resource AshGrant.Test.Payment        # Transaction limits
    resource AshGrant.Test.Journal        # Time/Period based
    resource AshGrant.Test.SharedDocument # Complex ownership + Multi-tenant
  end
end

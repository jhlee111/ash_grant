defmodule AshGrant.Test.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    # Basic resources
    resource(AshGrant.Test.Post)
    resource(AshGrant.Test.Comment)

    # Business scenario resources
    # Status-based workflow
    resource(AshGrant.Test.Document)
    # Organization hierarchy
    resource(AshGrant.Test.Employee)
    # Geographic/Territory
    resource(AshGrant.Test.Customer)
    # Security classification
    resource(AshGrant.Test.Report)
    # Project/Team
    resource(AshGrant.Test.Task)
    # Transaction limits
    resource(AshGrant.Test.Payment)
    # Time/Period based
    resource(AshGrant.Test.Journal)
    # Complex ownership + Multi-tenant
    resource(AshGrant.Test.SharedDocument)

    # Default policies test resource
    # Uses default_policies: true
    resource(AshGrant.Test.Article)

    # Multi-tenancy test resource
    # Uses ^tenant() scope expression
    resource(AshGrant.Test.TenantPost)

    # Instance permission read test resource
    resource(AshGrant.Test.SharedDoc)
  end
end

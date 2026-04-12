defmodule AshGrant.Test.Domain do
  @moduledoc false
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

    # Field-group column-level authorization test resource
    resource(AshGrant.Test.SensitiveRecord)

    # Field masking test resource
    resource(AshGrant.Test.MaskedRecord)

    # Field group except (blacklist) test resource
    resource(AshGrant.Test.ExceptRecord)

    # Overlapping field_group :always deduplication test resource
    resource(AshGrant.Test.OverlappingRecord)

    # Bulk operations test resources (exists() scope crash fix)
    resource(AshGrant.Test.BulkTeam)
    resource(AshGrant.Test.BulkMembership)
    resource(AshGrant.Test.BulkItem)

    # Instance key test resource (custom field for instance permission matching)
    resource(AshGrant.Test.Feed)

    # Scope through test resource (parent instance permission propagation)
    resource(AshGrant.Test.ChildComment)

    # Generic action test resource (action_input tenant extraction)
    resource(AshGrant.Test.ServiceRequest)
  end
end

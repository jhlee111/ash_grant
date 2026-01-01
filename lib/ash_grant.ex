defmodule AshGrant do
  @moduledoc """
  Permission-based authorization extension for Ash Framework.

  AshGrant provides a flexible, Apache Shiro-inspired **permission string** system
  that integrates seamlessly with Ash's policy authorizer. It combines:

  - **Permission-based access control** with `resource:instance:action:scope` matching
  - **Attribute-based scopes** for row-level filtering (ABAC-like)
  - **Instance-level permissions** for resource sharing (ReBAC-like)
  - **Deny-wins semantics** for intuitive permission overrides

  AshGrant focuses on permission evaluation, not role management. It works well
  on top of RBAC systems—just resolve roles to permissions in your resolver.

  ## Key Features

  - **Unified Permission Format**: `resource:instance_id:action:scope` syntax
  - **Instance-level permissions**: Share specific resources (like Google Docs sharing)
  - **Instance permissions with scopes (ABAC)**: Conditional instance access (`doc:doc_123:update:draft`)
  - **Deny-wins semantics**: Deny rules always override allow rules
  - **Wildcard matching**: `*` for resources/actions, `read*` for action prefixes
  - **Scope DSL**: Define scopes inline with `expr()` expressions
  - **Context injection**: Use `^context(:key)` for injectable/testable scopes
  - **Multi-tenancy Support**: Full support for `^tenant()` in scope expressions
  - **Two check types**: `filter_check/1` for reads, `check/1` for writes
  - **Default policies**: Auto-generate standard policies to reduce boilerplate

  ## Installation

  Add to your dependencies in `mix.exs`:

      def deps do
        [
          {:ash_grant, github: "jhlee111/ash_grant", tag: "v0.2.1"}
        ]
      end

  > **Note**: This package is not yet published to Hex.pm.

  ## Quick Start

  ### Minimal Setup (with Default Policies)

  With `default_policies: true`, you don't need to write any policy boilerplate:

      defmodule MyApp.Blog.Post do
        use Ash.Resource,
          domain: MyApp.Blog,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshGrant]

        ash_grant do
          resolver MyApp.PermissionResolver
          default_policies true  # Auto-generates read/write policies!

          scope :all, true
          scope :own, expr(author_id == ^actor(:id))
          scope :published, expr(status == :published)
        end

        # No policies block needed - AshGrant generates them automatically!
        # ... attributes, actions, etc.
      end

  ### Explicit Policies (Full Control)

  For more control, disable `default_policies` and define policies explicitly:

      defmodule MyApp.Blog.Post do
        use Ash.Resource,
          domain: MyApp.Blog,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshGrant]

        ash_grant do
          resolver MyApp.PermissionResolver
          resource_name "post"

          scope :all, true
          scope :own, expr(author_id == ^actor(:id))
          scope :published, expr(status == :published)
        end

        policies do
          bypass actor_attribute_equals(:role, :admin) do
            authorize_if always()
          end

          policy action_type(:read) do
            authorize_if AshGrant.filter_check()
          end

          policy action_type([:create, :update, :destroy]) do
            authorize_if AshGrant.check()
          end
        end
      end

  ### Implement a PermissionResolver

  The resolver fetches permissions for the current actor:

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(nil, _context), do: []

        @impl true
        def resolve(actor, _context) do
          actor
          |> get_roles()
          |> Enum.flat_map(& &1.permissions)
        end
      end

  ## Permission Format

  ### Unified 4-Part Format

      [!]resource:instance_id:action:scope

  | Component | Description | Examples |
  |-----------|-------------|----------|
  | `!` | Optional deny prefix | `!blog:*:delete:all` |
  | resource | Resource type or `*` | `blog`, `post`, `*` |
  | instance_id | Resource instance or `*` | `*`, `post_abc123xyz789ab` |
  | action | Action name or wildcard | `read`, `*`, `read*` |
  | scope | Access scope | `all`, `own`, `published`, or empty |

  ### RBAC Permissions (instance_id = `*`)

      "blog:*:read:all"           # Read all blogs
      "blog:*:read:published"     # Read only published blogs
      "blog:*:update:own"         # Update own blogs only
      "blog:*:*:all"              # All actions on all blogs
      "*:*:read:all"              # Read all resources
      "blog:*:read*:all"          # All read-type actions
      "!blog:*:delete:all"        # DENY delete on all blogs

  ### Instance Permissions (specific instance_id)

      "blog:post_abc123xyz789ab:read:"     # Read specific post
      "blog:post_abc123xyz789ab:*:"        # Full access to specific post
      "!blog:post_abc123xyz789ab:delete:"  # DENY delete on specific post

  ### Instance Permissions with Scopes (ABAC)

  Instance permissions can include scopes for attribute-based conditions:

      "doc:doc_123:update:draft"           # Update only when document is in draft
      "doc:doc_123:read:business_hours"    # Read only during business hours
      "invoice:inv_456:approve:small"      # Approve only if amount is small

  Use `AshGrant.Evaluator.get_instance_scope/3` to retrieve the scope condition.

  ## Scope DSL

  Define scopes inline using `expr()` expressions:

      ash_grant do
        scope :all, true
        scope :own, expr(author_id == ^actor(:id))
        scope :published, expr(status == :published)
        scope :own_draft, [:own], expr(status == :draft)  # Inheritance
      end

  ### Context Injection for Testable Scopes

  Use `^context(:key)` for injectable values instead of database functions:

      ash_grant do
        # Instead of: scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))
        # Use injectable context:
        scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))
        scope :threshold, expr(amount < ^context(:max_amount))
      end

  Inject values at query time:

      Post
      |> Ash.Query.for_read(:read)
      |> Ash.Query.set_context(%{reference_date: Date.utc_today()})
      |> Ash.read!(actor: actor)

  This enables deterministic testing by controlling the injected values.

  ## Deny-Wins Pattern

  When both allow and deny rules match, deny always takes precedence:

      permissions = [
        "blog:*:*:all",           # Allow all blog actions
        "!blog:*:delete:all"      # Deny delete
      ]

      # Result: read/update allowed, delete DENIED

  ## Check Types

  - `filter_check/1` - For read actions (returns filter expression)
  - `check/1` - For write actions (returns true/false)

  ## DSL Configuration

      ash_grant do
        resolver MyApp.PermissionResolver       # Required
        default_policies true                   # Optional: auto-generate policies
        resource_name "custom_name"             # Optional

        scope :all, true
        scope :own, expr(author_id == ^actor(:id))
        scope :same_tenant, expr(tenant_id == ^tenant())  # Multi-tenancy
      end

  | Option | Type | Description |
  |--------|------|-------------|
  | `resolver` | module/function | **Required.** Resolves permissions for actors |
  | `default_policies` | boolean/atom | Auto-generate policies: `true`, `:all`, `:read`, `:write` |
  | `resource_name` | string | Resource name for permission matching |

  ## Related Modules

  - `AshGrant.Permission` - Permission parsing and matching
  - `AshGrant.Evaluator` - Deny-wins permission evaluation
  - `AshGrant.PermissionResolver` - Behaviour for resolving permissions
  - `AshGrant.Check` - SimpleCheck for write actions
  - `AshGrant.FilterCheck` - FilterCheck for read actions
  - `AshGrant.Info` - DSL introspection helpers
  - `AshGrant.Transformers.AddDefaultPolicies` - Policy generation transformer
  """

  use Spark.Dsl.Extension,
    sections: AshGrant.Dsl.sections(),
    transformers: [AshGrant.Transformers.AddDefaultPolicies]

  @doc """
  Creates a simple check for write actions.

  This check returns true/false based on whether the actor
  has permission for the action.

  ## Options

  - `:action` - Override action name for permission matching
  - `:resource` - Override resource name for permission matching
  - `:subject` - Fields to use for condition evaluation

  ## Example

      policy action(:destroy) do
        authorize_if AshGrant.check()
      end

      policy action(:publish) do
        authorize_if AshGrant.check(action: "publish")
      end

  """
  defdelegate check(opts \\ []), to: AshGrant.Check

  @doc """
  Creates a filter check for read actions.

  This check returns a filter expression that limits results
  to records the actor can access.

  ## Options

  - `:action` - Override action name for permission matching
  - `:resource` - Override resource name for permission matching

  ## Example

      policy action_type(:read) do
        authorize_if AshGrant.filter_check()
      end

  """
  defdelegate filter_check(opts \\ []), to: AshGrant.FilterCheck
end

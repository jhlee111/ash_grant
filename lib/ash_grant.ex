defmodule AshGrant do
  @moduledoc """
  Permission-based authorization extension for Ash Framework.

  AshGrant provides a flexible, Apache Shiro-inspired permission system that
  integrates seamlessly with Ash's policy authorizer. It supports both
  role-based access control (RBAC) and resource-instance permissions.

  ## Key Features

  - **Apache Shiro-style permissions**: `resource:action:scope` format
  - **Instance-level permissions**: `resource:instance_id:action` (like Google Docs sharing)
  - **Deny-wins semantics**: Deny rules always override allow rules
  - **Wildcard matching**: `*` for resources/actions, `read*` for action prefixes
  - **Flexible scopes**: Define custom scopes (own, published, org_subtree, etc.)
  - **Two check types**: `filter_check/1` for reads, `check/1` for writes

  ## Installation

  Add to your dependencies in `mix.exs`:

      def deps do
        [
          {:ash_grant, "~> 0.1.0"}
        ]
      end

  ## Quick Start

  ### Step 1: Add the Extension to Your Resource

      defmodule MyApp.Blog.Post do
        use Ash.Resource,
          domain: MyApp.Blog,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshGrant]

        # Configure AshGrant
        ash_grant do
          resolver MyApp.PermissionResolver
          scope_resolver MyApp.ScopeResolver
          resource_name "post"        # Optional: defaults to "post"
          owner_field :author_id      # Optional: for "own" scope
        end

        # Define policies using AshGrant checks
        policies do
          # Admin bypass
          bypass actor_attribute_equals(:role, :admin) do
            authorize_if always()
          end

          # Read actions: use filter_check (returns filtered results)
          policy action_type(:read) do
            authorize_if AshGrant.filter_check()
          end

          # Write actions: use check (returns true/false)
          policy action_type([:create, :update, :destroy]) do
            authorize_if AshGrant.check()
          end
        end
      end

  ### Step 2: Implement a PermissionResolver

  The resolver fetches permissions for the current actor:

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(nil, _context), do: []

        @impl true
        def resolve(actor, _context) do
          # Get permissions from user's roles
          actor
          |> get_roles()
          |> Enum.flat_map(& &1.permissions)
        end
      end

  ### Step 3: Implement a ScopeResolver

  The resolver translates scope strings to Ash filter expressions:

      defmodule MyApp.ScopeResolver do
        @behaviour AshGrant.ScopeResolver
        require Ash.Expr

        @impl true
        def resolve("all", _context), do: true

        @impl true
        def resolve("own", %{actor: actor, owner_field: field}) do
          Ash.Expr.expr(^ref(field) == ^actor.id)
        end

        @impl true
        def resolve("published", _context) do
          Ash.Expr.expr(status == :published)
        end
      end

  ## Permission Format

  ### Role-based Permissions (RBAC)

      [!]resource:action:scope

  | Component | Description | Examples |
  |-----------|-------------|----------|
  | `!` | Optional deny prefix | `!blog:delete:all` |
  | resource | Resource type or `*` | `blog`, `post`, `*` |
  | action | Action name or wildcard | `read`, `*`, `read*` |
  | scope | Access scope | `all`, `own`, `published` |

  **Examples:**

      "blog:read:all"           # Read all blogs
      "blog:read:published"     # Read only published blogs
      "blog:update:own"         # Update own blogs only
      "blog:*:all"              # All actions on all blogs
      "*:read:all"              # Read all resources
      "blog:read*:all"          # All read-type actions (read, read_all, read_draft)
      "!blog:delete:all"        # Deny delete on all blogs

  ### Instance-level Permissions

  For sharing specific resources (like Google Docs), use the prefixed ID directly:

      [!]prefixed_id:action

  The prefix of the ID (e.g., `feed` in `feed_abc123xyz789ab`) identifies the
  resource type, so no separate resource field is needed.

  **Examples:**

      "feed_abc123xyz789ab:read"      # Read access to specific feed
      "doc_xyz789abc123xy:*"          # Full access to specific document
      "!feed_abc123xyz789ab:delete"   # Deny delete on specific feed

  ## Deny-Wins Pattern

  When both allow and deny rules match, deny always takes precedence:

      permissions = [
        "blog:*:all",           # Allow all blog actions
        "!blog:delete:all"      # Deny delete
      ]

      # Result:
      # - blog:read   → allowed
      # - blog:update → allowed
      # - blog:delete → denied (deny wins)

  This pattern is useful for:

  - Revoking specific permissions from broad grants
  - Creating "except" rules (e.g., "all except delete")
  - Implementing inheritance with overrides

  ## Check Types

  ### `filter_check/1` - For Read Actions

  Returns a filter expression that limits query results to accessible records.
  Best for `:read` action types where you want to show only permitted data.

      policy action_type(:read) do
        authorize_if AshGrant.filter_check()
      end

  ### `check/1` - For Write Actions

  Returns `true` or `false` based on whether the actor has permission.
  Best for `:create`, `:update`, `:destroy` actions.

      policy action(:destroy) do
        authorize_if AshGrant.check()
      end

  ## DSL Configuration

      ash_grant do
        resolver MyApp.PermissionResolver       # Required
        scope_resolver MyApp.ScopeResolver      # Optional
        resource_name "custom_name"             # Optional
        owner_field :user_id                    # Optional
      end

  | Option | Type | Description |
  |--------|------|-------------|
  | `resolver` | module or function | **Required.** Resolves permissions for actors |
  | `scope_resolver` | module or function | Translates scopes to filter expressions |
  | `resource_name` | string | Resource name for permission matching (default: derived from module) |
  | `owner_field` | atom | Field for "own" scope resolution |

  ## Architecture

      ┌──────────────────────────────────────────────────────────────────┐
      │                        Ash Policy Check                          │
      └──────────────────────────────────────────────────────────────────┘
                                    │
                      ┌─────────────┴─────────────┐
                      │                           │
                ┌─────▼─────┐              ┌──────▼──────┐
                │  Check    │              │ FilterCheck │
                │ (writes)  │              │  (reads)    │
                └─────┬─────┘              └──────┬──────┘
                      │                           │
                      └───────────┬───────────────┘
                                  │
                      ┌───────────▼───────────┐
                      │ PermissionResolver    │
                      │ (actor → permissions) │
                      └───────────┬───────────┘
                                  │
                      ┌───────────▼───────────┐
                      │ Evaluator             │
                      │ (deny-wins matching)  │
                      └───────────┬───────────┘
                                  │
                      ┌───────────▼───────────┐
                      │ ScopeResolver         │
                      │ (scope → filter)      │
                      └───────────────────────┘

  ## Related Modules

  - `AshGrant.Permission` - Permission parsing and matching
  - `AshGrant.Evaluator` - Deny-wins permission evaluation
  - `AshGrant.PermissionResolver` - Behaviour for resolving permissions
  - `AshGrant.ScopeResolver` - Behaviour for scope resolution
  - `AshGrant.Check` - SimpleCheck for write actions
  - `AshGrant.FilterCheck` - FilterCheck for read actions
  - `AshGrant.Info` - DSL introspection helpers
  """

  use Spark.Dsl.Extension,
    sections: AshGrant.Dsl.sections(),
    transformers: []

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

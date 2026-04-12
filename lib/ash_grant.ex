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

  - **Unified Permission Format**: `resource:instance_id:action:scope[:field_group]` syntax (4-part or 5-part)
  - **Field-level permissions**: Column-level read access via field groups with inheritance and masking
  - **Instance-level permissions**: Share specific resources (like Google Docs sharing)
  - **Instance permissions with scopes (ABAC)**: Conditional instance access (`doc:doc_123:update:draft`)
  - **Deny-wins semantics**: Deny rules always override allow rules
  - **Wildcard matching**: `*` for resources/actions, `read*` for action types
  - **Scope DSL**: Define scopes inline with `expr()` expressions
  - **Context injection**: Use `^context(:key)` for injectable/testable scopes
  - **Multi-tenancy Support**: Full support for `^tenant()` in scope expressions
  - **Three check types**: `filter_check/1` for reads, `check/1` for writes, `field_check/1` for field-level access
  - **Default policies**: Auto-generate standard policies to reduce boilerplate

  ## Installation

  See the [README](https://github.com/jhlee111/ash_grant#installation) for installation instructions.

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

          scope :always, true
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

          scope :always, true
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

  ### Permissions with Metadata (for debugging)

  Return `AshGrant.PermissionInput` structs for enhanced debugging and `explain/4`:

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          actor
          |> get_roles()
          |> Enum.flat_map(fn role ->
            Enum.map(role.permissions, fn perm ->
              %AshGrant.PermissionInput{
                string: perm,
                description: "From role permissions",
                source: "role:\#{role.name}"
              }
            end)
          end)
        end
      end

  ### Custom Structs with Permissionable Protocol

  Implement the `AshGrant.Permissionable` protocol for your custom structs:

      defmodule MyApp.RolePermission do
        defstruct [:permission_string, :label, :role_name]
      end

      defimpl AshGrant.Permissionable, for: MyApp.RolePermission do
        def to_permission_input(%MyApp.RolePermission{} = rp) do
          %AshGrant.PermissionInput{
            string: rp.permission_string,
            description: rp.label,
            source: "role:\#{rp.role_name}"
          }
        end
      end

      # Then just return your structs from the resolver
      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          MyApp.Accounts.get_role_permissions(actor)
        end
      end

  ## Permission Format

  ### Permission String Format

      [!]resource:instance_id:action:scope[:field_group]

  | Component | Description | Examples |
  |-----------|-------------|----------|
  | `!` | Optional deny prefix | `!blog:*:delete:all` |
  | resource | Resource type or `*` | `blog`, `post`, `*` |
  | instance_id | Resource instance or `*` | `*`, `post_abc123xyz789ab` |
  | action | Action name or wildcard | `read`, `*`, `read*` |
  | scope | Access scope | `all`, `own`, `published`, or empty |
  | field_group | Optional column-level group | `public`, `sensitive`, `confidential` |

  The 5th part (`field_group`) is optional. When omitted (4-part format), all fields are visible.

  ### RBAC Permissions (instance_id = `*`)

      "blog:*:read:always"           # Read all blogs
      "blog:*:read:published"     # Read only published blogs
      "blog:*:update:own"         # Update own blogs only
      "blog:*:*:always"              # All actions on all blogs
      "*:*:read:always"              # Read all resources
      "blog:*:read*:always"          # All read-type actions
      "!blog:*:delete:always"        # DENY delete on all blogs

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
        scope :always, true
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
        "blog:*:*:always",           # Allow all blog actions
        "!blog:*:delete:always"      # Deny delete
      ]

      # Result: read/update allowed, delete DENIED

  ## Check Types

  - `filter_check/1` - For read actions (returns filter expression)
  - `check/1` - For write actions (returns true/false)

  > #### `exists()` scopes and write actions {: .warning}
  >
  > Scopes using `exists()` are only fully enforced for read actions, where
  > `FilterCheck` converts them to SQL EXISTS subqueries. For write actions,
  > `Check` evaluates scopes in-memory and cannot resolve `exists()` — the
  > relational condition is replaced with `true`. Attribute-based conditions
  > in the same scope are still checked. A compile-time warning is emitted
  > for affected scopes. See `AshGrant.Check` for details.

  ## DSL Configuration

      ash_grant do
        resolver MyApp.PermissionResolver       # Required
        default_policies true                   # Optional: auto-generate policies
        resource_name "custom_name"             # Optional

        scope :always, true
        scope :own, expr(author_id == ^actor(:id))
        scope :same_tenant, expr(tenant_id == ^tenant())  # Multi-tenancy

        # UI visibility — auto-generates :can_update? and :can_destroy? calculations
        can_perform_actions [:update, :destroy]

        # Or individually with custom name
        can_perform :read, name: :visible?

        # Field groups (whitelist)
        field_group :public, [:name, :department]
        field_group :sensitive, [:phone, :address], inherits: [:public]

        # Field groups (blacklist with except)
        # field_group :public, :all, except: [:salary, :ssn]
      end

  | Option | Type | Description |
  |--------|------|-------------|
  | `resolver` | module/function | **Required.** Resolves permissions for actors |
  | `default_policies` | boolean/atom | Auto-generate policies: `true`, `:all`, `:read`, `:write` |
  | `can_perform_actions` | list of atoms | Batch-generate CanPerform calculations |
  | `resource_name` | string | Resource name for permission matching |

  ## Related Modules

  - `AshGrant.Permission` - Permission parsing and matching (4-part and 5-part formats)
  - `AshGrant.PermissionInput` - Permission input with metadata for debugging
  - `AshGrant.Permissionable` - Protocol for converting custom structs to permissions
  - `AshGrant.Evaluator` - Deny-wins permission evaluation with field group support
  - `AshGrant.PermissionResolver` - Behaviour for resolving permissions
  - `AshGrant.Check` - SimpleCheck for write actions
  - `AshGrant.FilterCheck` - FilterCheck for read actions
  - `AshGrant.FieldCheck` - SimpleCheck for field-level authorization in `field_policies`
  - `AshGrant.Info` - DSL introspection helpers (scopes, field groups, configuration)
  - `AshGrant.Introspect` - Runtime permission introspection for UIs and APIs
  - `AshGrant.Explanation` - Authorization decision explanation struct
  - `AshGrant.Transformers.AddDefaultPolicies` - Policy generation transformer
  - `AshGrant.Transformers.AddCanPerformCalculations` - CanPerform calculation generation from DSL
  """

  use Spark.Dsl.Extension,
    sections: AshGrant.Dsl.sections(),
    transformers: [
      AshGrant.Transformers.MergeDomainConfig,
      AshGrant.Transformers.ValidateResolverPresent,
      AshGrant.Transformers.ValidateScopes,
      AshGrant.Transformers.ValidateScopeThroughs,
      AshGrant.Transformers.ResolveFieldGroupFields,
      AshGrant.Transformers.ValidateFieldGroups,
      AshGrant.Transformers.AddDefaultPolicies,
      AshGrant.Transformers.AddFieldPolicies,
      AshGrant.Transformers.AddMaskingPreparation,
      AshGrant.Transformers.AddCanPerformCalculations
    ]

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

  @doc """
  Creates a field check for use in Ash's `field_policies`.

  The check passes if the actor's permission includes the specified field group
  or a field group that inherits from it. If the actor's permissions use the
  4-part format (no field_group), all fields are visible.

  ## Example

      field_policies do
        field_policy [:salary, :ssn] do
          authorize_if AshGrant.field_check(:confidential)
        end
      end

  """
  defdelegate field_check(field_group), to: AshGrant.FieldCheck

  @doc """
  Explains an authorization decision for debugging.

  Returns an `AshGrant.Explanation` struct with detailed information about
  why access was allowed or denied, including:

  - All matching permissions with their metadata (description, source)
  - All evaluated permissions with match/no-match reasons
  - Scope information from both permissions and DSL definitions
  - The final decision and reason

  ## Parameters

  - `resource` - The Ash resource module
  - `action` - The action atom (e.g., `:read`, `:update`)
  - `actor` - The actor performing the action
  - `context` - Optional context map (default: `%{}`)

  ## Examples

      # Basic usage
      iex> AshGrant.explain(MyApp.Post, :read, actor)
      %AshGrant.Explanation{
        decision: :allow,
        matching_permissions: [%{permission: "post:*:read:always", ...}],
        ...
      }

      # With context
      iex> AshGrant.explain(MyApp.Post, :read, actor, %{tenant: "acme"})
      %AshGrant.Explanation{...}

      # Print human-readable output
      iex> AshGrant.explain(MyApp.Post, :read, actor) |> AshGrant.Explanation.to_string() |> IO.puts()
      ═══════════════════════════════════════════════════════════════════
      Authorization Explanation for MyApp.Post
      ═══════════════════════════════════════════════════════════════════
      Action:   read
      Decision: ✓ ALLOW
      ...

  ## Use Cases

  - **Debugging**: Understand why a request was denied
  - **Testing**: Verify permissions work as expected
  - **Auditing**: Log detailed authorization decisions
  - **Admin tools**: Build permission debugging UIs

  """
  @spec explain(module(), atom(), term(), map()) :: AshGrant.Explanation.t()
  def explain(resource, action, actor, context \\ %{}) do
    AshGrant.Explainer.explain(resource, action, actor, context)
  end
end

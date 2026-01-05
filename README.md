# AshGrant

Permission-based authorization extension for [Ash Framework](https://ash-hq.org/).

AshGrant provides a flexible, Apache Shiro-inspired **permission string** system
that integrates seamlessly with Ash's policy authorizer. It combines:

- **Permission-based access control** with `resource:instance:action:scope` matching
- **Attribute-based scopes** for row-level filtering (ABAC-like)
- **Instance-level permissions** for resource sharing (ReBAC-like)
- **Deny-wins semantics** for intuitive permission overrides

AshGrant focuses on permission evaluation, not role management. It works well
on top of RBAC systems—just resolve roles to permissions in your resolver.

## Features

- **Unified Permission Format**: `resource:instance_id:action:scope` syntax
- **Instance-level permissions**: Share specific resources (like Google Docs sharing)
- **Deny-wins semantics**: Deny rules always override allow rules
- **Wildcard matching**: `*` for resources/actions, `read*` for action prefixes
- **Scope DSL**: Define scopes inline with `expr()` expressions
- **Multi-tenancy Support**: Full support for `^tenant()` in scope expressions
- **Two check types**: `filter_check/1` for reads, `check/1` for writes
- **Default policies**: Auto-generate standard policies to reduce boilerplate
- **Permission metadata**: Optional `description` and `source` fields for debugging
- **Permissionable protocol**: Convert custom structs to permissions with zero boilerplate

## Installation

Add `ash_grant` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_grant, github: "jhlee111/ash_grant", tag: "v0.3.1"}
  ]
end
```

> **Note**: This package is not yet published to Hex.pm. It will be available via `{:ash_grant, "~> 0.5.0"}` once published.

## Quick Start

### 1. Add the Extension to Your Resource (Minimal Setup)

With `default_policies: true`, you don't need to write any policy boilerplate:

```elixir
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
```

### 1b. Explicit Policies (Full Control)

For more control, you can disable `default_policies` and define policies explicitly:

```elixir
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
    scope :own_draft, [:own], expr(status == :draft)
  end

  # Define policies explicitly for full control
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

  # ... attributes, actions, etc.
end
```

### 2. Implement a PermissionResolver

The resolver fetches permissions for the current actor:

```elixir
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
```

### 2b. Permissions with Metadata (for debugging)

Return `AshGrant.PermissionInput` structs for enhanced debugging and `explain/4`:

```elixir
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
          source: "role:#{role.name}"
        }
      end)
    end)
  end
end
```

### 2c. Custom Structs with Permissionable Protocol

Implement the `AshGrant.Permissionable` protocol for your custom structs:

```elixir
defmodule MyApp.RolePermission do
  defstruct [:permission_string, :label, :role_name]
end

defimpl AshGrant.Permissionable, for: MyApp.RolePermission do
  def to_permission_input(%MyApp.RolePermission{} = rp) do
    %AshGrant.PermissionInput{
      string: rp.permission_string,
      description: rp.label,
      source: "role:#{rp.role_name}"
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
```

## Permission Format

### Unified 4-Part Format

```
[!]resource:instance_id:action:scope
```

| Component | Description | Examples |
|-----------|-------------|----------|
| `!` | Optional deny prefix | `!blog:*:delete:all` |
| resource | Resource type or `*` | `blog`, `post`, `*` |
| instance_id | Resource instance or `*` | `*`, `post_abc123xyz789ab` |
| action | Action name or wildcard | `read`, `*`, `read*` |
| scope | Access scope | `all`, `own`, `published`, or empty |

### RBAC Permissions (instance_id = `*`)

```elixir
"blog:*:read:all"           # Read all blogs
"blog:*:read:published"     # Read only published blogs
"blog:*:update:own"         # Update own blogs only
"blog:*:*:all"              # All actions on all blogs
"*:*:read:all"              # Read all resources
"blog:*:read*:all"          # All read-type actions
"!blog:*:delete:all"        # DENY delete on all blogs
```

### Instance Permissions (specific instance_id)

For sharing specific resources (like Google Docs):

```elixir
"blog:post_abc123xyz789ab:read:"     # Read specific post
"blog:post_abc123xyz789ab:*:"        # Full access to specific post
"!blog:post_abc123xyz789ab:delete:"  # DENY delete on specific post
```

Instance permissions have an empty scope (trailing colon) because the permission
is already scoped to a specific instance.

> **Note**: Instance permissions currently work with write actions (`check/1`).
> Support for read actions (`filter_check/1`) is planned for a future release.

### Legacy Format Support

For backward compatibility, shorter formats are still supported:

```elixir
"blog:read:all"    # Parsed as blog:*:read:all
"blog:read"        # Parsed as blog:*:read:
```

## Scope DSL

Define scopes inline using the `scope` entity. The `expr` macro is automatically
available within the `ash_grant` block.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  # Boolean scope - no filtering
  scope :all, true

  # Expression scope - filter by condition
  scope :own, expr(author_id == ^actor(:id))
  scope :published, expr(status == :published)

  # Inherited scope - combines parent with additional filter
  scope :own_draft, [:own], expr(status == :draft)
  # Result: author_id == actor.id AND status == :draft
end
```

### Scope Inheritance

Scopes can inherit from parent scopes:

```elixir
scope :base, expr(tenant_id == ^actor(:tenant_id))
scope :active, [:base], expr(status == :active)
# Result: tenant_id == actor.tenant_id AND status == :active
```

### Example: Date-Based Scopes

You can use SQL fragments for temporal filtering:

```elixir
# Records created today only
scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))

# Combined with ownership
scope :own_today, [:own], expr(fragment("DATE(inserted_at) = CURRENT_DATE"))
```

## Deny-Wins Pattern

When both allow and deny rules match, deny always takes precedence:

```elixir
permissions = [
  "blog:*:*:all",           # Allow all blog actions
  "!blog:*:delete:all"      # Deny delete
]

# Result:
# - blog:read   -> allowed
# - blog:update -> allowed
# - blog:delete -> DENIED (deny wins)
```

This pattern is useful for:

- Revoking specific permissions from broad grants
- Creating "except" rules (e.g., "all except delete")
- Implementing inheritance with overrides

## Check Types

### `filter_check/1` - For Read Actions

Returns a filter expression that limits query results to accessible records:

```elixir
policy action_type(:read) do
  authorize_if AshGrant.filter_check()
end
```

### `check/1` - For Write Actions

Returns `true` or `false` based on whether the actor has permission:

```elixir
policy action(:destroy) do
  authorize_if AshGrant.check()
end
```

## DSL Configuration

```elixir
ash_grant do
  resolver MyApp.PermissionResolver       # Required
  default_policies true                   # Optional: auto-generate policies
  resource_name "custom_name"             # Optional

  # Inline scopes
  scope :all, true
  scope :own, expr(owner_id == ^actor(:id))
end
```

| Option | Type | Description |
|--------|------|-------------|
| `resolver` | module or function | **Required.** Resolves permissions for actors |
| `default_policies` | boolean or atom | Auto-generate policies: `true`, `:all`, `:read`, or `:write` |
| `resource_name` | string | Resource name for permission matching (default: derived from module) |

### Default Policies Options

The `default_policies` option controls automatic policy generation:

| Value | Description |
|-------|-------------|
| `false` | No policies generated (default). You must define policies explicitly. |
| `true` or `:all` | Generate both read and write policies |
| `:read` | Only generate `filter_check()` policy for read actions |
| `:write` | Only generate `check()` policy for write actions |

**Generated policies when `default_policies: true`:**

```elixir
policies do
  policy action_type(:read) do
    authorize_if AshGrant.filter_check()
  end

  policy action_type([:create, :update, :destroy]) do
    authorize_if AshGrant.check()
  end
end
```

## Advanced Usage

### Action Override

Map different Ash actions to the same permission:

```elixir
# Both :get_by_id and :list use "read" permission
policy action([:read, :get_by_id, :list]) do
  authorize_if AshGrant.filter_check(action: "read")
end
```

### Multiple Scopes

When an actor has permissions with multiple scopes, they're combined with OR:

```elixir
# Actor has: ["post:*:read:own", "post:*:read:published"]
# Result filter: author_id == actor.id OR status == :published
```

### Organization Hierarchy Scopes

For multi-tenant apps with org hierarchies:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :all, true

  scope :org_self, expr(organization_unit_id == ^actor(:org_unit_id))

  # For complex scopes requiring runtime data, use scope_resolver
end
```

### Multi-Tenancy Support

AshGrant fully supports Ash's multi-tenancy with the `^tenant()` template:

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        %{role: :tenant_admin} -> ["post:*:*:same_tenant"]
        %{role: :tenant_user} -> ["post:*:read:same_tenant", "post:*:update:own_in_tenant"]
        _ -> []
      end
    end

    default_policies true

    # Tenant-based scopes using ^tenant()
    scope :all, true
    scope :same_tenant, expr(tenant_id == ^tenant())
    scope :own, expr(author_id == ^actor(:id))
    scope :own_in_tenant, [:same_tenant], expr(author_id == ^actor(:id))
  end

  # ...
end
```

**Usage with tenant context:**

```elixir
# Read - only returns posts from the specified tenant
posts = Post |> Ash.read!(actor: user, tenant: tenant_id)

# Create - validated against tenant scope
Ash.create(Post, %{title: "Hello", tenant_id: tenant_id},
  actor: user,
  tenant: tenant_id
)

# Update - must match both tenant AND ownership for own_in_tenant scope
Ash.update(post, %{title: "Updated"}, actor: user, tenant: tenant_id)
```

**Key points:**
- Use `^tenant()` to reference the current tenant from query/changeset context
- Use `^actor(:tenant_id)` if tenant is stored on the actor instead
- Scope inheritance works with tenant scopes (e.g., `[:same_tenant]`)
- Both `filter_check` (reads) and `check` (writes) properly evaluate tenant scopes

## Business Scope Examples

AshGrant supports a wide variety of business scenarios. Here are common patterns:

### Status-Based Workflow

```elixir
ash_grant do
  scope :all, true
  scope :draft, expr(status == :draft)
  scope :pending_review, expr(status == :pending_review)
  scope :approved, expr(status == :approved)
  scope :editable, expr(status in [:draft, :pending_review])
end
```

### Security Classification

Hierarchical access levels:

```elixir
ash_grant do
  scope :public, expr(classification == :public)
  scope :internal, expr(classification in [:public, :internal])
  scope :confidential, expr(classification in [:public, :internal, :confidential])
  scope :top_secret, true  # Can see all
end
```

### Transaction Limits

Numeric comparisons for amount-based authorization:

```elixir
ash_grant do
  scope :small_amount, expr(amount < 1000)
  scope :medium_amount, expr(amount < 10000)
  scope :large_amount, expr(amount < 100000)
  scope :unlimited, true
end
```

### Multi-Tenant with Inheritance

Combined scopes using inheritance:

```elixir
ash_grant do
  scope :tenant, expr(tenant_id == ^actor(:tenant_id))
  scope :tenant_active, [:tenant], expr(status == :active)
  scope :tenant_own, [:tenant], expr(created_by_id == ^actor(:id))
end
```

### Time/Period Based

Temporal filtering:

```elixir
ash_grant do
  scope :current_period, expr(period_id == ^actor(:current_period_id))
  scope :open_periods, expr(period_status == :open)
  scope :this_fiscal_year, expr(fiscal_year == ^actor(:fiscal_year))
end
```

### Geographic/Territory

List membership for territory assignments:

```elixir
ash_grant do
  scope :same_region, expr(region_id == ^actor(:region_id))
  scope :assigned_territories, expr(territory_id in ^actor(:territory_ids))
  scope :my_accounts, expr(account_manager_id == ^actor(:id))
end
```

### Legacy ScopeResolver

For complex scopes that require runtime data fetching, you can still use
a separate `ScopeResolver` module (deprecated, prefer inline scopes):

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope_resolver MyApp.ScopeResolver  # Deprecated
end
```

## Architecture

```
                    Ash Policy Check
                          |
            +-------------+-------------+
            |                           |
      +-----v-----+              +------v------+
      |  Check    |              | FilterCheck |
      | (writes)  |              |  (reads)    |
      +-----+-----+              +------+------+
            |                           |
            +-----------+---------------+
                        |
            +-----------v-----------+
            | PermissionResolver    |
            | (actor -> permissions)|
            +-----------+-----------+
                        |
            +-----------v-----------+
            | Evaluator             |
            | (deny-wins matching)  |
            +-----------+-----------+
                        |
            +-----------v-----------+
            | Scope DSL / Resolver  |
            | (scope -> filter)     |
            +-----------------------+
```

## Debugging with `explain/4`

Use `AshGrant.explain/4` to understand why authorization succeeded or failed:

```elixir
# Get detailed explanation
result = AshGrant.explain(MyApp.Post, :read, actor)

# Check the decision
result.decision  # => :allow or :deny

# See matching permissions with metadata
result.matching_permissions
# => [%{permission: "post:*:read:all", description: "Read all posts", source: "editor_role", ...}]

# See why permissions didn't match
result.evaluated_permissions
# => [%{permission: "post:*:update:own", matched: false, reason: "Action mismatch"}, ...]

# Print human-readable output
result |> AshGrant.Explanation.to_string() |> IO.puts()
```

**Sample output:**

```
═══════════════════════════════════════════════════════════════════
Authorization Explanation for MyApp.Blog.Post
═══════════════════════════════════════════════════════════════════
Action:   read
Decision: ✓ ALLOW
Actor:    %{id: "user-1", role: :editor}

Matching Permissions:
  • post:*:read:all [scope: all - All records without restriction] (from: editor_role)
    └─ Read all posts

Scope Filter: true (no filtering)
───────────────────────────────────────────────────────────────────
```

### Scope Descriptions

Add descriptions to scopes for better debugging output:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :all, [], true, description: "All records without restriction"
  scope :own, [], expr(author_id == ^actor(:id)), description: "Records owned by the current user"
  scope :published, [], expr(status == :published), description: "Published records visible to everyone"
end
```

Access scope descriptions programmatically:

```elixir
AshGrant.Info.scope_description(MyApp.Post, :own)
# => "Records owned by the current user"
```

## API Reference

### Modules

| Module | Description |
|--------|-------------|
| `AshGrant` | Main extension module with `check/1`, `filter_check/1`, and `explain/4` |
| `AshGrant.Explanation` | Authorization decision explanation struct |
| `AshGrant.Explainer` | Builds detailed authorization explanations |
| `AshGrant.Permission` | Permission parsing and matching |
| `AshGrant.PermissionInput` | Permission input with metadata for debugging |
| `AshGrant.Permissionable` | Protocol for converting custom structs to permissions |
| `AshGrant.Evaluator` | Deny-wins permission evaluation |
| `AshGrant.PermissionResolver` | Behaviour for resolving permissions |
| `AshGrant.ScopeResolver` | Behaviour for scope resolution (legacy) |
| `AshGrant.Check` | SimpleCheck for write actions |
| `AshGrant.FilterCheck` | FilterCheck for read actions |
| `AshGrant.Info` | DSL introspection helpers |

## Testing

AshGrant includes comprehensive tests using `Ash.Generator` for fixture generation:

```bash
mix test
```

The test suite covers:

- **Permission parsing** - All format variants and edge cases
- **Evaluator** - Deny-wins semantics with property-based tests
- **DB Integration** - Real database queries with scope filtering
- **Business scenarios** - 8 different authorization patterns:
  - Status-based workflow (Document)
  - Organization hierarchy (Employee)
  - Geographic/Territory (Customer)
  - Security classification (Report)
  - Project/Team assignment (Task)
  - Transaction limits (Payment)
  - Time/Period based (Journal)
  - Complex ownership + Multi-tenant (SharedDocument)

Each scenario tests both positive (can access) and negative (cannot access) cases,
plus deny-wins semantics and edge conditions.

## License

MIT License - see [LICENSE](LICENSE) for details.

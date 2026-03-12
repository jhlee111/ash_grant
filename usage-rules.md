# AshGrant Usage Rules

> These rules help LLMs correctly use AshGrant — a permission-based authorization
> extension for Ash Framework. Follow them when generating code that uses AshGrant.

## What AshGrant Is

AshGrant is a **permission evaluation** extension, not a role management system.
It evaluates permission strings against resources and actions using deny-wins semantics.
It integrates with Ash's policy authorizer via three check types.

Roles, role assignments, and permission storage are **your responsibility**.
AshGrant only needs a resolver that returns permission strings for a given actor.

## Permission String Format

```
[!]resource:instance_id:action:scope[:field_group]
```

| Part          | Required | Description                                      |
|---------------|----------|--------------------------------------------------|
| `!`           | No       | Deny prefix — deny rules always override allows  |
| `resource`    | Yes      | Resource name or `*` for all                     |
| `instance_id` | Yes      | `*` for RBAC, specific ID for instance access    |
| `action`      | Yes      | Action name, `*` for all, or `prefix*` wildcard  |
| `scope`       | Yes      | Scope name (e.g., `all`, `own`) or empty string  |
| `field_group` | No       | 5th part for column-level access control         |

### RBAC permissions (instance_id = `*`)

```elixir
"blog:*:read:all"           # Read all blogs
"blog:*:read:published"     # Read only published blogs
"blog:*:update:own"         # Update own blogs only
"blog:*:*:all"              # All actions on all blogs
"*:*:read:all"              # Read all resources
"blog:*:read*:all"          # All read-type actions (read, read_all, etc.)
"!blog:*:delete:all"        # DENY delete on all blogs
```

### Instance permissions (specific instance_id)

```elixir
"blog:post_abc123:read:"        # Read specific post (no scope condition)
"blog:post_abc123:*:"           # Full access to specific post
"!blog:post_abc123:delete:"     # DENY delete on specific post
"doc:doc_123:update:draft"      # Update only when document is in draft (ABAC)
```

Instance permissions with an empty scope (trailing colon) mean unconditional access.
Instance permissions with a scope name impose an attribute-based condition.

### Field-level permissions (5-part format)

```elixir
"employee:*:read:all:public"       # See only public fields
"employee:*:read:all:sensitive"    # See public + sensitive fields
"employee:*:read:all:confidential" # See all fields including confidential
```

When the 5th part is omitted (4-part format), all fields are visible.

## Resource Setup

### Always include these three things

1. `authorizers: [Ash.Policy.Authorizer]` in resource options
2. `extensions: [AshGrant]` in resource options
3. An `ash_grant` block with at least a `resolver` and one scope

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    scope :all, true
    scope :own, expr(author_id == ^actor(:id))
  end
end
```

### DO: Use `default_policies: true` to eliminate boilerplate

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true  # Generates read + write policies automatically

  scope :all, true
  scope :own, expr(author_id == ^actor(:id))
end
# No policies block needed!
```

### DO: Use explicit policies when you need bypasses or custom logic

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope :all, true
  scope :own, expr(author_id == ^actor(:id))
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
```

### DON'T: Use both `default_policies: true` and a manual `policies` block

The transformer adds policies automatically. Defining both creates conflicts.

### DON'T: Forget `authorizers: [Ash.Policy.Authorizer]`

AshGrant generates policy checks, but Ash must be told to enforce them.

## DSL Configuration

### `ash_grant` block options

| Option                 | Type              | Required | Default | Description                                                  |
|------------------------|-------------------|----------|---------|--------------------------------------------------------------|
| `resolver`             | module or fun/2   | Yes      | —       | Resolves permissions for actors                              |
| `default_policies`     | bool/atom         | No       | `false` | `true`, `:all`, `:read`, or `:write`                        |
| `default_field_policies`| boolean          | No       | `false` | Auto-generate `field_policies` from `field_group` definitions|
| `resource_name`        | string            | No       | derived | Override resource name for permission matching               |

`resource_name` defaults to the last segment of the module name, lowercased
(e.g., `MyApp.Blog.Post` becomes `"post"`).

### Scope entity

```elixir
scope :name, filter_expression
scope :name, [:parent_scopes], filter_expression
scope :name, filter_expression, description: "Human-readable text"
scope :name, filter_expression, write: write_expression
```

- Use `true` for a scope that matches all records (no filtering).
- Use `expr(...)` for attribute-based filtering.
- Use the optional second argument (list of atoms) to inherit from parent scopes.
- Use `write:` to provide a separate expression for write actions (see below).

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :all, true
  scope :own, expr(author_id == ^actor(:id))
  scope :published, expr(status == :published)
  scope :own_draft, [:own], expr(status == :draft)  # own AND draft
  scope :same_tenant, expr(tenant_id == ^tenant())  # Multi-tenancy
end
```

### Dual read/write scope (`write:` option)

Scopes with `exists()` or dot-paths work automatically for both reads and writes.
For reads, they are converted to SQL. For writes, a **DB query fallback** verifies
the scope by querying the database with the read scope expression.

You can optionally use the `write:` option to explicitly control write behavior:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  # No write: needed — DB query fallback handles it automatically
  scope :team_member, expr(exists(team.members, user_id == ^actor(:id)))

  # Explicit override: in-memory expression (avoids DB round-trip)
  scope :same_org, expr(exists(org.users, id == ^actor(:id))),
    write: expr(org_id == ^actor(:org_id))

  # Explicitly deny writes with this scope
  scope :readonly, expr(exists(org.users, id == ^actor(:id))),
    write: false

  # No write: option — simple scopes use in-memory evaluation (no DB needed)
  scope :own, expr(author_id == ^actor(:id))
end
```

| `write:` value | Strategy | Behavior for write actions |
|----------------|----------|---------------------------|
| omitted, no relationships | In-memory | Evaluates filter expression in-memory |
| omitted, has relationships | DB query | Queries DB with read scope expression |
| `expr(...)` | In-memory | Uses the provided expression |
| `false` | Deny | Denies all write actions with this scope |
| `true` | Allow | Allows all write actions (no filtering) |

Inheritance works with `write:`: child scopes inherit the parent's `write:`
expression (or parent's `filter` if parent has no `write:`). If any parent
returns `false`, the child is also denied.

### Field group entity

```elixir
field_group :name, [:field1, :field2]
field_group :name, [:field1, :field2], inherits: [:parent_groups]
```

Field groups define sets of fields for column-level read authorization.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  field_group :public, [:name, :department, :position]
  field_group :sensitive, [:phone, :address], inherits: [:public]          # Inherits public
  field_group :confidential, [:salary, :ssn], inherits: [:sensitive]      # Inherits sensitive
end
```

## Scope Patterns

### Actor references

Use `^actor(:field)` to reference the current actor's attributes:

```elixir
scope :own, expr(author_id == ^actor(:id))
scope :same_org, expr(org_id == ^actor(:org_id))
```

### Tenant references

Use `^tenant()` for multi-tenant scopes:

```elixir
scope :same_tenant, expr(tenant_id == ^tenant())
```

### Context injection

Use `^context(:key)` for injectable, testable values:

```elixir
# Definition
scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))
scope :threshold, expr(amount < ^context(:max_amount))

# Usage — inject at query time
Post
|> Ash.Query.for_read(:read)
|> Ash.Query.set_context(%{reference_date: Date.utc_today()})
|> Ash.read!(actor: actor)
```

### DO: Prefer `^context(:key)` over database functions for testability

```elixir
# DO
scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))

# DON'T
scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))
```

### Scope inheritance

Child scopes combine parent filters with AND logic:

```elixir
scope :own, expr(author_id == ^actor(:id))
scope :own_draft, [:own], expr(status == :draft)
# Effective filter: author_id == ^actor(:id) AND status == :draft
```

## Check Types

AshGrant provides three check types. Use the right one for each action type.

### `AshGrant.filter_check/1` — for read actions

Returns a filter expression that limits query results. Supports `exists()` scopes
because filters are converted to SQL.

```elixir
policy action_type(:read) do
  authorize_if AshGrant.filter_check()
end
```

### `AshGrant.check/1` — for write actions

Returns true/false by evaluating the scope in-memory against the record.

```elixir
policy action_type([:create, :update, :destroy]) do
  authorize_if AshGrant.check()
end
```

### `AshGrant.field_check/1` — for field-level access

Used inside Ash's `field_policies` block to control column visibility.

```elixir
field_policies do
  field_policy [:salary, :ssn] do
    authorize_if AshGrant.field_check(:confidential)
  end

  field_policy :* do
    authorize_if always()
  end
end
```

### DO: Override action names when Ash action names differ from permission actions

```elixir
policy action(:publish) do
  authorize_if AshGrant.check(action: "update")
end

policy action(:list_published) do
  authorize_if AshGrant.filter_check(action: "read")
end
```

### DON'T: Use `filter_check` for write actions or `check` for read actions

- `filter_check` returns filter expressions — meaningless for writes.
- `check` returns true/false — doesn't filter read results.

### DO: Use `exists()` scopes freely — DB query fallback handles writes

Scopes with `exists()` or dot-paths work automatically for all action types.
For writes, a DB query verifies the scope when no `write:` option is set.

```elixir
# DO — works for both reads and writes automatically
scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))
```

### DO: Use `write:` when you want explicit control

Use `write:` to override the automatic DB query strategy:

```elixir
# Explicit in-memory expression (avoids DB query overhead)
scope :same_org, expr(exists(org.users, id == ^actor(:id))),
  write: expr(org_id == ^actor(:org_id))

# Explicitly deny writes
scope :readonly, expr(exists(org.users, id == ^actor(:id))),
  write: false
```

## Deny-Wins Semantics

When both allow and deny rules match, **deny always wins**:

```elixir
permissions = [
  "blog:*:*:all",        # Allow all blog actions
  "!blog:*:delete:all"   # Deny delete
]

# Result: read ✓, update ✓, delete ✗ (deny wins)
```

Evaluation rules:
1. If **any** deny rule matches → **denied**
2. If no deny matches and at least one allow matches → **allowed**
3. If **no** rules match → **denied** (deny by default)

## PermissionResolver Behaviour

Implement `AshGrant.PermissionResolver` to provide permissions for actors.

### Simple resolver (returns strings)

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(nil, _context), do: []

  @impl true
  def resolve(actor, _context) do
    actor
    |> MyApp.Accounts.get_roles()
    |> Enum.flat_map(& &1.permissions)
  end
end
```

### Resolver with metadata (for debugging with `explain/4`)

Return `AshGrant.PermissionInput` structs to include source tracking:

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(nil, _context), do: []

  @impl true
  def resolve(actor, _context) do
    actor
    |> MyApp.Accounts.get_roles()
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

### Custom structs with the Permissionable protocol

Implement `AshGrant.Permissionable` for your own structs:

```elixir
defimpl AshGrant.Permissionable, for: MyApp.RolePermission do
  def to_permission_input(%MyApp.RolePermission{} = rp) do
    %AshGrant.PermissionInput{
      string: rp.permission_string,
      description: rp.label,
      source: "role:#{rp.role_name}"
    }
  end
end
```

### DON'T: Return nil from the resolver

Always return an empty list `[]` for unauthenticated or unknown actors.

## Default Policies

`default_policies` controls automatic policy generation:

| Value    | Read policy | Write policy |
|----------|-------------|--------------|
| `false`  | No          | No           |
| `true`   | Yes         | Yes          |
| `:all`   | Yes         | Yes          |
| `:read`  | Yes         | No           |
| `:write` | No          | Yes          |

Generated policies are equivalent to:

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

Use `:read` or `:write` when you need auto-generation for one type and
explicit control over the other.

## Instance Permissions

Instance permissions enable resource-sharing patterns (like Google Docs sharing).

```elixir
# Grant user access to a specific document
"document:doc_abc123:read:"     # Read access (no conditions)
"document:doc_abc123:*:"        # Full access

# Grant conditional instance access (ABAC)
"document:doc_abc123:update:draft"  # Update only when in draft status
```

For read actions, `FilterCheck` automatically builds `WHERE id IN (...)` filters
from instance permissions and combines them with RBAC scope filters using OR.

## Field-Level Permissions

### Manual field policies (Mode A)

Write `field_policies` yourself using `AshGrant.field_check/1`:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  field_group :public, [:name, :department]
  field_group :sensitive, [:phone, :address], inherits: [:public]
  field_group :confidential, [:salary, :ssn], inherits: [:sensitive]
end

field_policies do
  field_policy [:salary, :ssn] do
    authorize_if AshGrant.field_check(:confidential)
  end

  field_policy [:phone, :address] do
    authorize_if AshGrant.field_check(:sensitive)
  end

  field_policy :* do
    authorize_if always()
  end
end
```

### Auto-generated field policies (Mode B)

Set `default_field_policies: true` to auto-generate from field group definitions:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_field_policies true

  field_group :public, [:name, :department]
  field_group :sensitive, [:phone, :address], inherits: [:public]
  field_group :confidential, [:salary, :ssn], inherits: [:sensitive]
end
# field_policies block is generated automatically
```

### Field group inheritance

Field groups support inheritance. A group that inherits from another includes
all of the parent's fields plus its own:

```
:public        → [:name, :department]
:sensitive     → [:name, :department, :phone, :address]       (inherits :public)
:confidential  → [:name, :department, :phone, :address, :salary, :ssn]  (inherits :sensitive)
```

If an actor's permission uses the 4-part format (no field_group), all fields
are visible. The 5th part only restricts when explicitly present.

## Debugging

### `AshGrant.explain/4`

Returns an `AshGrant.Explanation` struct with details about an authorization decision:

```elixir
explanation = AshGrant.explain(MyApp.Post, :read, actor)

# Print human-readable output
explanation |> AshGrant.Explanation.to_string() |> IO.puts()
```

The explanation includes:
- All matching permissions with metadata (description, source)
- All evaluated permissions with match/no-match reasons
- Scope information and field groups
- The final decision and reason

### `AshGrant.Introspect`

Runtime introspection for building admin UIs and permission management:

```elixir
# Check if actor can perform an action
AshGrant.Introspect.can?(MyApp.Post, :read, actor)
# => :allow or :deny

# List all allowed actions
AshGrant.Introspect.allowed_actions(MyApp.Post, actor)

# Get all permissions with their status
AshGrant.Introspect.actor_permissions(MyApp.Post, actor)

# List all possible permissions for a resource
AshGrant.Introspect.available_permissions(MyApp.Post)
```

### `AshGrant.Info`

DSL introspection helpers for accessing configuration at runtime:

```elixir
AshGrant.Info.resolver(MyApp.Post)        # The configured resolver module
AshGrant.Info.scopes(MyApp.Post)          # List of scope definitions
AshGrant.Info.field_groups(MyApp.Post)    # List of field group definitions
AshGrant.Info.resource_name(MyApp.Post)   # The resource name string
```

## Policy Testing

### `mix ash_grant.verify`

Run policy configuration tests defined in YAML or Elixir files:

```bash
# Run all YAML tests in default directories
mix ash_grant.verify

# Run a specific file
mix ash_grant.verify path/to/test.yaml --verbose

# Run all tests in a directory
mix ash_grant.verify priv/policy_tests/

# Run an Elixir fixture file
mix ash_grant.verify test/support/policy_test_fixtures.ex
```

### YAML test format

```yaml
resource: MyApp.Blog.Post
tests:
  - name: "Editor can read all posts"
    actor:
      role: editor
      permissions:
        - "post:*:read:all"
    action: read
    expected: allow
```

## Common Mistakes

### Using `check()` for read actions

```elixir
# WRONG — check() returns true/false, doesn't filter results
policy action_type(:read) do
  authorize_if AshGrant.check()
end

# CORRECT
policy action_type(:read) do
  authorize_if AshGrant.filter_check()
end
```

### Missing the `:all` scope

Every resource with AshGrant should define a `:all` scope. Without it,
permissions like `"post:*:read:all"` will raise a runtime error because
the scope `"all"` cannot be resolved.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope :all, true  # Always include this
  scope :own, expr(author_id == ^actor(:id))
end
```

### Using `exists()` scopes without a data layer

The DB query fallback requires a data layer (e.g., AshPostgres). For resources
without a data layer, `exists()` conditions are replaced with `true` during
in-memory evaluation. Use `write:` to provide a direct-field expression:

```elixir
# For resources WITHOUT a data layer, use write: to provide an alternative
scope :same_org, expr(exists(org.users, id == ^actor(:id))),
  write: expr(org_id == ^actor(:org_id))
```

### Forgetting that deny-wins means no order dependency

Deny rules win regardless of where they appear in the permission list.
You cannot "override" a deny with a later allow.

```elixir
# These are equivalent — deny ALWAYS wins
["!post:*:delete:all", "post:*:*:all"]
["post:*:*:all", "!post:*:delete:all"]
```

### Using wrong permission format for instances

```elixir
# WRONG — 3-part format is legacy and may be ambiguous
"blog:post_abc123:read"

# CORRECT — use 4-part format with trailing colon for no-scope instance access
"blog:post_abc123:read:"
```

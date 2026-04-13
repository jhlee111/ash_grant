# Scopes

Scopes define row-level filters referenced by permission strings. They are written inline
using the `scope` entity with Ash `expr()` expressions.

## Scope DSL

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  # Boolean scope - no filtering
  scope :always, true

  # Expression scope - filter by condition
  scope :own, expr(author_id == ^actor(:id))
  scope :published, expr(status == :published)

  # Inherited scope - combines parent with additional filter
  scope :own_draft, [:own], expr(status == :draft)
  # Result: author_id == actor.id AND status == :draft

  # Relational scope - works for both reads and writes automatically
  scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))
end
```

## Scope Inheritance

Scopes can inherit from parent scopes:

```elixir
scope :base, expr(tenant_id == ^actor(:tenant_id))
scope :active, [:base], expr(status == :active)
# Result: tenant_id == actor.tenant_id AND status == :active
```

## Scope Combination Rules

### Multiple Permissions = OR

When an actor has **multiple permissions** with different scopes for the same action,
they are combined with **OR**:

```elixir
# Actor has both permissions:
["post:*:read:own", "post:*:read:published"]

# Result filter: (author_id == actor.id) OR (status == :published)
# Actor can see their own posts AND all published posts
```

### Scope Inheritance = AND

When a scope **inherits** from parent scopes, they are combined with **AND**:

```elixir
ash_grant do
  scope :own, expr(author_id == ^actor(:id))
  scope :draft, expr(status == :draft)
  scope :own_draft, [:own], expr(status == :draft)
  # Inheritance: [:own] + expr(status == :draft)
end

# :own_draft filter: (author_id == actor.id) AND (status == :draft)
# NOT the same as having two separate permissions!
```

> **Key difference:** Multiple permissions expand access (OR),
> scope inheritance restricts access (AND).

## Date-Based Scopes

You can use SQL fragments for temporal filtering:

```elixir
# Records created today only
scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))

# Combined with ownership
scope :own_today, [:own], expr(fragment("DATE(inserted_at) = CURRENT_DATE"))
```

## Multi-Tenancy Support

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
    scope :always, true
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

### Two Approaches

| Approach | Use When |
|----------|----------|
| `^tenant()` | Using Ash's multi-tenancy features, tenant can change per-request |
| `^actor(:tenant_id)` | Tenant is fixed per user, simpler setup |

**Option 1: `^tenant()` - Context-based (Recommended)**

Uses Ash's built-in tenant context, passed via query/changeset options:

```elixir
ash_grant do
  scope :same_tenant, expr(tenant_id == ^tenant())
end

# Usage - tenant comes from Ash context
Post |> Ash.read!(actor: user, tenant: "acme_corp")
```

**Option 2: `^actor(:tenant_id)` - Actor-based**

Uses a tenant_id field stored on the actor:

```elixir
ash_grant do
  scope :same_tenant, expr(tenant_id == ^actor(:tenant_id))
end

# Usage - tenant comes from actor struct
actor = %User{id: 1, tenant_id: "acme_corp"}
Post |> Ash.read!(actor: actor)
```

> **Warning:** Don't mix approaches in the same resource. Pick one and be consistent.

**Key points:**
- Use `^tenant()` to reference the current tenant from query/changeset context
- Use `^actor(:tenant_id)` if tenant is stored on the actor instead
- Scope inheritance works with tenant scopes (e.g., `[:same_tenant]`)
- Both `filter_check` (reads) and `check` (writes) properly evaluate tenant scopes

## Relational Scopes (`exists()` and Dot-Paths)

You can use `exists()` and dot-path references in scope expressions for relationship-based filtering.
These work for both **read** and **write** actions:

```elixir
ash_grant do
  scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))
  scope :own_in_team, expr(author_id == ^actor(:id) and exists(team.memberships, user_id == ^actor(:id)))
  scope :same_center, expr(order.center_id == ^actor(:center_id))
end
```

For **read** actions, `FilterCheck` converts these to SQL (EXISTS subquery or JOIN).
For **write** actions, `Check` automatically uses a **DB query fallback** when the
scope contains relationship references — the read scope expression is used as a DB
query to verify the record matches the scope.

### Recommended: argument-based scopes for multi-hop authorization

For write-action authorization that reaches through relationships
(e.g., `refund → order → center_id`), prefer an argument-based scope paired
with `resolve_argument`. The scope stays in-memory-evaluable and the resource
populates the argument from its own relationships:

```elixir
ash_grant do
  scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
  resolve_argument :center_id, from_path: [:order, :center_id]
end
```

See [Argument-Based Scope](argument-based-scope.md) for the full pattern.

> **Deprecated: `write:` override**
>
> The `write:` option was introduced as an escape hatch when the main
> `filter` could not be evaluated in memory on write actions. It is
> deprecated as of 0.14 — prefer argument-based scopes + `resolve_argument`
> for multi-hop cases, or use a separate scope name for read-only semantics.
>
> Using `write:` still works but emits a compile-time deprecation warning.

## Business Scope Examples

AshGrant supports a wide variety of business scenarios. Here are common patterns:

### Status-Based Workflow

```elixir
ash_grant do
  scope :always, true
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

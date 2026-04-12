# Authorization Patterns

This guide shows how AshGrant implements common authorization models — RBAC, ABAC, ReBAC —
and additional patterns like deny-wins, field-level access, and multi-tenancy. Each section
includes the scope DSL, resolver examples, and usage.

> **Prerequisite:** Familiarity with [Permissions](permissions.md) and [Scopes](scopes.md).

## RBAC (Role-Based Access Control)

RBAC assigns permissions to roles, and roles to users. This is AshGrant's default mode —
any permission with `instance_id = *` is an RBAC permission.

**Permission format:** `resource:*:action:scope`

### Resource Setup

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    default_policies true

    scope :always, true
    scope :own, expr(author_id == ^actor(:id))
    scope :published, expr(status == :published)
  end
end
```

### Resolver

The resolver maps roles to permission strings:

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(%{role: :admin}, _context) do
    ["post:*:*:always"]                                      # Full access
  end

  def resolve(%{role: :editor}, _context) do
    ["post:*:read:always", "post:*:update:always"]              # Read + update all
  end

  def resolve(%{role: :author}, _context) do
    ["post:*:read:always", "post:*:update:own"]              # Read all, update own
  end

  def resolve(%{role: :viewer}, _context) do
    ["post:*:read:published"]                             # Published only
  end

  def resolve(_, _context), do: []
end
```

### How It Works

| Role | Permission | Resulting Filter |
|------|-----------|------------------|
| Admin | `post:*:*:always` | No filter (sees everything) |
| Editor | `post:*:update:always` | No filter on updates |
| Author | `post:*:update:own` | `WHERE author_id = actor.id` |
| Viewer | `post:*:read:published` | `WHERE status = 'published'` |

The `*` wildcard in the instance_id position means "all instances" — this is what makes
it RBAC rather than instance-level access.

### When to Use

- Clear organizational roles (admin, editor, viewer)
- Permissions don't depend on resource attributes beyond scope
- Simple applications where role explosion is not a concern

---

## ABAC (Attribute-Based Access Control)

ABAC makes decisions based on attributes of the user, the resource, and the environment.
AshGrant's `expr()` scope system is fundamentally an ABAC engine — every scope is an
attribute-based policy expression.

### User Attribute Conditions

Filter by properties of the actor:

```elixir
ash_grant do
  # Same department
  scope :same_department, expr(department_id == ^actor(:department_id))

  # Same region
  scope :same_region, expr(region_id == ^actor(:region_id))

  # Assigned territories (list membership)
  scope :assigned_territories, expr(territory_id in ^actor(:territory_ids))

  # Actor's team
  scope :my_team, expr(team_id == ^actor(:team_id))
end
```

### Resource Attribute Conditions

Filter by properties of the resource itself:

```elixir
ash_grant do
  # Status-based workflow
  scope :always, true
  scope :draft, expr(status == :draft)
  scope :approved, expr(status == :approved)
  scope :editable, expr(status in [:draft, :pending_review])

  # Transaction amount limits
  scope :small_amount, expr(amount < 1000)
  scope :medium_amount, expr(amount < 10_000)
  scope :large_amount, expr(amount < 100_000)
  scope :unlimited, true

  # Security classification (hierarchical)
  scope :public, expr(classification == :public)
  scope :internal, expr(classification in [:public, :internal])
  scope :confidential, expr(classification in [:public, :internal, :confidential])
  scope :top_secret, true
end
```

### Environment/Context Conditions

Filter by external context like time or injected parameters:

```elixir
ash_grant do
  # Business hours only
  scope :business_hours, expr(
    fragment("EXTRACT(HOUR FROM NOW()) BETWEEN 9 AND 17")
  )

  # Timezone-aware business hours (injected context)
  scope :business_hours_local, expr(
    fragment(
      "EXTRACT(HOUR FROM ?::timestamptz AT TIME ZONE ?) BETWEEN 9 AND 17",
      ^context(:current_time),
      ^context(:timezone)
    )
  )

  # Records from a specific date (injected)
  scope :on_date, expr(
    fragment("DATE(inserted_at) = ?", ^context(:reference_date))
  )

  # Fiscal period (actor-bound)
  scope :current_period, expr(period_id == ^actor(:current_period_id))
  scope :this_fiscal_year, expr(fiscal_year == ^actor(:fiscal_year))
end
```

### Combining Conditions with Scope Inheritance

Scope inheritance lets you AND conditions together — combining user, resource, and
context attributes in a single scope:

```elixir
ash_grant do
  scope :own, expr(author_id == ^actor(:id))
  scope :same_tenant, expr(tenant_id == ^actor(:tenant_id))

  # Own + draft status = "my drafts only"
  scope :own_draft, [:own], expr(status == :draft)

  # Same tenant + active = "active records in my tenant"
  scope :tenant_active, [:same_tenant], expr(status == :active)

  # Same tenant + own = "my records in my tenant"
  scope :tenant_own, [:same_tenant], expr(created_by_id == ^actor(:id))
end
```

> **Remember:** Scope inheritance = AND (restricts access). Multiple permissions = OR
> (expands access). See the [Scopes guide](scopes.md#scope-combination-rules) for details.

### Example: Amount-Based Authorization

A complete example showing transaction limit tiers:

```elixir
# Resource
ash_grant do
  resolver MyApp.PaymentResolver
  default_policies true

  scope :always, true
  scope :small_amount, expr(amount < 1000)
  scope :medium_amount, expr(amount < 10_000)
  scope :large_amount, expr(amount < 100_000)
  scope :unlimited, true
end

# Resolver
defmodule MyApp.PaymentResolver do
  @behaviour AshGrant.PermissionResolver

  def resolve(%{role: :clerk}, _ctx),           do: ["payment:*:read:small_amount"]
  def resolve(%{role: :accountant}, _ctx),      do: ["payment:*:read:medium_amount"]
  def resolve(%{role: :finance_manager}, _ctx), do: ["payment:*:read:large_amount"]
  def resolve(%{role: :cfo}, _ctx),             do: ["payment:*:*:unlimited"]
  def resolve(_, _ctx), do: []
end

# Result:
# Clerk sees payments < 1,000
# Accountant sees payments < 10,000
# Finance Manager sees payments < 100,000
# CFO sees all payments
```

### When to Use

- Access depends on dynamic attributes (department, region, amount, time)
- Fine-grained policies beyond simple role mapping
- Conditions that combine user context with resource state

---

## ReBAC (Relationship-Based Access Control)

ReBAC determines access based on relationships between users and resources — ownership,
membership, collaboration, or hierarchy. AshGrant supports this through four mechanisms.

### Method 1: Instance Permissions

Grant access to specific resource instances by ID:

```elixir
# Resolver generates instance permissions from relationships
defmodule MyApp.DocResolver do
  @behaviour AshGrant.PermissionResolver

  def resolve(actor, _context) do
    # RBAC: user can always read their own docs
    rbac = ["document:*:read:own", "document:*:update:own"]

    # Instance: docs explicitly shared with this user
    shared = actor.shared_doc_ids
    |> Enum.map(&"document:#{&1}:read:")

    rbac ++ shared
  end
end
```

The resulting filter combines both with OR:

```
(owner_id == actor.id) OR (id IN [shared_doc_ids])
```

### Method 2: `exists()` — Relationship Traversal

Use `exists()` to filter through join tables and associations:

```elixir
ash_grant do
  scope :always, true
  scope :own, expr(author_id == ^actor(:id))

  # N:M relationship — team membership via join table
  scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))

  # Combined: own AND in team
  scope :own_in_team, expr(
    author_id == ^actor(:id) and exists(team.memberships, user_id == ^actor(:id))
  )

  # Dot-path: check parent relationship attribute
  scope :named_team, expr(team.name == ^actor(:team_name))
end
```

For **read** actions, these compile to SQL (EXISTS subquery or JOIN).
For **write** actions, AshGrant automatically uses a DB query fallback to verify
the record matches the scope.

### Method 3: `scope_through` — Parent-Child Propagation

Propagate a parent resource's instance permissions to child resources:

```elixir
defmodule MyApp.Comment do
  use Ash.Resource, extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    default_policies true

    scope :always, true
    scope :own, expr(user_id == ^actor(:id))

    # Comments inherit Post's instance permissions
    scope_through :post
  end

  relationships do
    belongs_to :post, MyApp.Post
  end
end
```

When a user has `"post:post_123:read:"`, they can also read all comments where
`post_id == "post_123"`. This propagation works for reads, writes, and CanPerform
calculations.

### Method 4: Organizational Hierarchy

Model tree-structured access with list membership:

```elixir
ash_grant do
  scope :always, true

  # Same organizational unit
  scope :org_self, expr(organization_unit_id == ^actor(:org_unit_id))

  # Direct child units
  scope :org_children, expr(organization_unit_id in ^actor(:child_org_ids))

  # Entire subtree (self + all descendants)
  scope :org_subtree, expr(organization_unit_id in ^actor(:subtree_org_ids))
end

# Resolver
def resolve(%{role: :team_lead} = actor, _ctx) do
  ["employee:*:read:org_children"]   # See direct reports
end

def resolve(%{role: :director} = actor, _ctx) do
  ["employee:*:read:org_subtree"]    # See entire division
end
```

> **Tip:** The resolver is responsible for computing `child_org_ids` or `subtree_org_ids`
> and placing them on the actor struct. AshGrant evaluates the scope expression — it does
> not traverse the graph itself.

### When to Use

- Document sharing (owner + collaborators)
- Team/project membership
- Parent-child resource hierarchies (feed → posts → comments)
- Organizational charts with nested access

---

## Additional Patterns

### Deny-Wins (Negative Permissions)

The `!` prefix creates deny rules that always override allow rules:

```elixir
permissions = [
  "post:*:*:always",              # Allow everything
  "!post:*:delete:always"         # Deny delete — always wins
]

# read   → allowed
# update → allowed
# delete → DENIED
```

Use deny rules for:

- Revoking specific permissions from broad grants
- "Everything except X" patterns
- Safety guardrails that override role-based grants

### Multi-Tenancy

AshGrant supports tenant isolation using `^tenant()` or `^actor(:tenant_id)`:

```elixir
ash_grant do
  scope :always, true
  scope :same_tenant, expr(tenant_id == ^tenant())
  scope :own, expr(author_id == ^actor(:id))
  scope :own_in_tenant, [:same_tenant], expr(author_id == ^actor(:id))
end
```

```elixir
# Tenant admin sees everything in their tenant
# Tenant user sees only their own records within the tenant
def resolve(%{role: :tenant_admin}, _ctx), do: ["post:*:*:same_tenant"]
def resolve(%{role: :tenant_user}, _ctx) do
  ["post:*:read:same_tenant", "post:*:update:own_in_tenant"]
end
```

See the [Scopes guide](scopes.md#multi-tenancy-support) for detailed setup.

### Field-Level Access (Column-Level Authorization)

Control which fields are visible based on permissions:

```elixir
ash_grant do
  scope :always, true
  default_field_policies true

  field_group :public, [:name, :department, :position]
  field_group :sensitive, [:phone, :address], inherits: [:public]
  field_group :confidential, [:salary, :email], inherits: [:sensitive]
end
```

```elixir
# Permission with field_group (5th component)
"employee:*:read:always:public"          # → sees name, department, position
"employee:*:read:always:sensitive"       # → + phone, address
"employee:*:read:always:confidential"    # → + salary, email (everything)
```

See the [Field-Level Permissions guide](field-level-permissions.md) for masking and
blacklist mode.

### Domain-Level Inheritance

Share resolver and scopes across all resources in a domain:

```elixir
defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshGrant.Domain]

  ash_grant do
    resolver MyApp.PermissionResolver

    scope :always, true
    scope :own, expr(author_id == ^actor(:id))
  end

  resources do
    resource MyApp.Blog.Post     # Inherits resolver + scopes
    resource MyApp.Blog.Comment  # Inherits resolver + scopes
  end
end
```

Resources can add extra scopes or override inherited ones:

```elixir
# Inherits :always and :own from domain, adds :published
ash_grant do
  default_policies true
  scope :published, expr(status == :published)
end
```

### CanPerform (UI Visibility)

Generate per-record boolean calculations for frontend use:

```elixir
ash_grant do
  can_perform_actions [:update, :destroy]

  # Or with a custom name
  can_perform :read, name: :visible?
end
```

```elixir
# Load calculations with the record
posts = Post |> Ash.read!(actor: user, load: [:can_update?, :can_destroy?])

Enum.each(posts, fn post ->
  IO.puts("#{post.title}: edit=#{post.can_update?}, delete=#{post.can_destroy?}")
end)
```

---

## Pattern Comparison

| Pattern | AshGrant Mechanism | Granularity | Complexity |
|---------|-------------------|-------------|------------|
| RBAC | `resource:*:action:scope` | Low | Low |
| ABAC | `expr()` with `^actor()`, `^context()`, `fragment()` | High | Moderate |
| ReBAC | Instance permissions, `exists()`, `scope_through` | High | Moderate |
| Deny-Wins | `!` prefix | — | Low |
| Field-Level | `field_group` entities | Column-level | Low |
| Multi-Tenant | `^tenant()` in scopes | Tenant-level | Low |
| Hierarchical | `in ^actor(:subtree_ids)` | Tree-level | Moderate |

### Choosing a Pattern

- **Start with RBAC** for straightforward role-to-permission mapping.
- **Add ABAC scopes** when access depends on resource attributes (status, amount, region).
- **Add ReBAC** when access depends on relationships (ownership, membership, hierarchy).
- **Combine freely** — AshGrant's scope system lets you mix patterns. A single resource
  can use RBAC permissions with ABAC scopes, instance-level ReBAC, deny rules, and
  field-level restrictions simultaneously.

```elixir
# Example: all patterns combined
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true
  default_field_policies true

  # RBAC scopes
  scope :always, true
  scope :own, expr(author_id == ^actor(:id))

  # ABAC scopes
  scope :same_tenant, expr(tenant_id == ^actor(:tenant_id))
  scope :active, expr(status == :active)
  scope :tenant_own, [:same_tenant], expr(author_id == ^actor(:id))

  # ReBAC
  scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))
  scope_through :feed

  # Field-level
  field_group :public, [:title, :body]
  field_group :internal, [:notes, :score], inherits: [:public]

  # UI visibility
  can_perform_actions [:update, :destroy]
end
```

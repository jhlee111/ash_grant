# AshGrant

Permission-based authorization extension for [Ash Framework](https://ash-hq.org/).

AshGrant connects three Ash-native concepts — **resources**, **actions**, and
**`expr()` scopes** — through a permission string (`[!]resource:instance_id:action:scope[:field_group]`).
Permissions resolve to native Ash filters and policy checks, with deny-wins semantics.

**Authorization:**
- **Scope DSL** with `expr()` — row-level filters, scope inheritance, `^tenant()` support
- **Field groups** — column-level read access with inheritance and masking
- **Instance permissions** — per-record sharing with optional scope conditions
- **Deny-wins evaluation** — deny rules always override allows

**Verification & Tooling:**
- **`explain/4`** — trace why authorization succeeded or failed
- **`Introspect`** — query actor permissions, available actions at runtime
- **Policy testing** — DSL and YAML-based config tests, no database required

AshGrant handles permission evaluation, not role management. Resolve roles to
permission strings in your resolver.

## Installation

Add `ash_grant` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_grant, "~> 0.6"}
  ]
end
```

## Quick Start

### 1. Add the Extension to Your Resource

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    # Resolver converts actor to permission strings
    resolver fn actor, _context ->
      case actor do
        %{role: :admin} -> ["post:*:*:all"]           # Full access
        %{role: :editor} -> [
          "post:*:read:all",                          # Read all posts
          "post:*:create:all",                        # Create posts
          "post:*:update:own"                         # Update own posts only
        ]
        %{role: :viewer} -> ["post:*:read:published"] # Read published only
        _ -> []
      end
    end

    default_policies true  # Auto-generates read/write policies

    # Scopes define row-level filters (referenced by permission strings)
    scope :all, true
    scope :own, expr(author_id == ^actor(:id))
    scope :published, expr(status == :published)
  end

  # ... attributes, actions, etc.
end
```

**How it works:**
1. Actor (`%{role: :editor, id: "user_123"}`) is passed to the resolver
2. Resolver returns permission strings like `"post:*:update:own"`
3. Permission `post:*:update:own` references scope `:own`
4. Scope `:own` adds filter `author_id == actor.id` to queries

### 2. Use It

```elixir
# Editor can read all posts
editor = %{id: "user_123", role: :editor}
Post |> Ash.read!(actor: editor)

# Editor can only update their own posts
Ash.update!(post, %{title: "New Title"}, actor: editor)
# => Succeeds if post.author_id == "user_123"
# => Fails if post.author_id != "user_123"

# Viewer can only read published posts
viewer = %{id: "user_456", role: :viewer}
Post |> Ash.read!(actor: viewer)
# => Returns only posts where status == :published
```

### 3. Module-Based Resolver (Production)

For production, extract the resolver to a module:

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(nil, _context), do: []

  @impl true
  def resolve(actor, _context) do
    # Load permissions from database
    actor
    |> MyApp.Accounts.get_user_permissions()
    |> Enum.map(& &1.permission_string)
  end
end
```

Then reference it in your resource:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  # ...
end
```

### 4. Explicit Policies (Full Control)

For more control, disable `default_policies` and define policies explicitly:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  # default_policies false (default)

  scope :all, true
  scope :own, expr(author_id == ^actor(:id))
end

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
```

#### Resolver Context

The `context` parameter passed to your resolver contains:

| Key | Type | Description |
|-----|------|-------------|
| `:actor` | term | The actor performing the action |
| `:resource` | module | The Ash resource module |
| `:action` | Ash.Action.t | The action struct |
| `:tenant` | term \| nil | Current tenant (from query/changeset) |
| `:changeset` | Ash.Changeset.t \| nil | For write actions |
| `:query` | Ash.Query.t \| nil | For read actions |

**Example usage:**

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(actor, context) do
    base_permissions = get_role_permissions(actor)

    # Add instance permissions based on context
    case context do
      %{resource: MyApp.Document, action: %{name: :read}} ->
        shared_docs = get_shared_document_ids(actor)
        instance_perms = Enum.map(shared_docs, &"document:#{&1}:read:")
        base_permissions ++ instance_perms

      _ ->
        base_permissions
    end
  end
end
```

## Resolver Patterns

### Permissions with Metadata

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

### Custom Structs with Permissionable Protocol

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

### Permission String Format (Apache Shiro-Inspired)

```
[!]resource:instance_id:action:scope[:field_group]
```

| Component | Description | Examples |
|-----------|-------------|----------|
| `!` | Optional deny prefix | `!blog:*:delete:all` |
| resource | Resource type or `*` | `blog`, `post`, `*` |
| instance_id | Resource instance or `*` | `*`, `post_abc123xyz789ab` |
| action | Action name or wildcard | `read`, `*`, `read*` |
| scope | Access scope | `all`, `own`, `published`, or empty |
| field_group | Optional column-level group | `public`, `sensitive`, `confidential` |

The 5th part (`field_group`) is optional. When omitted (4-part format), all fields are visible.
When present, only fields in the named group (and its inherited parents) are accessible.

### Wildcard Matching Rules

| Component | `*` (all) | `prefix*` | Exact match |
|-----------|-----------|-----------|-------------|
| resource | Yes | No | Yes |
| instance_id | Yes | No | Yes |
| action | Yes | Yes | Yes |
| scope | No | No | Yes |

**Examples:**

```elixir
"*:*:read:all"       # All resources, read action
"blog*:*:read:all"   # Invalid - resource doesn't support prefix
"blog:*:read*:all"   # Valid - action supports prefix (read, read_all, etc.)
"blog:post_*:read:"  # Invalid - instance_id doesn't support prefix
```

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

#### Instance Permissions with Scopes (ABAC)

Instance permissions can include scope conditions for attribute-based access control:

```elixir
# Permission format: resource:instance_id:action:scope
"doc:doc_123:update:draft"    # Can update doc_123 only when in draft status
"doc:doc_123:read:"           # Can read doc_123 unconditionally (empty scope)
```

**Define the scope in your resource:**

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :draft, expr(status == :draft)
  scope :business_hours, expr(fragment("EXTRACT(HOUR FROM NOW()) BETWEEN 9 AND 17"))
end
```

**How it works:**

1. For **read** actions: `filter_check` adds the scope filter to the query
2. For **write** actions: `check` evaluates the scope against the target record

```elixir
# User has: "doc:doc_123:update:draft"

# This succeeds (doc is in draft)
Ash.update!(draft_doc, %{title: "New"}, actor: user)

# This fails (doc is published, not draft)
Ash.update!(published_doc, %{title: "New"}, actor: user)
```

Instance permissions work with both:
- **Read actions** (`filter_check/1`) - Adds `WHERE id IN (instance_ids)` filter
- **Write actions** (`check/1`) - Validates access to specific instance

#### Instance Permission Read Example

```elixir
# Resolver returns instance permissions for shared documents
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  def resolve(%{shared_doc_ids: doc_ids}, _context) when is_list(doc_ids) do
    # Generate instance permission for each shared document
    Enum.map(doc_ids, fn doc_id ->
      "document:#{doc_id}:read:"
    end)
  end
end

# User can only read documents explicitly shared with them
actor = %{id: "user-1", shared_doc_ids: ["doc_abc", "doc_xyz"]}
Document |> Ash.read!(actor: actor)
# => Returns only doc_abc and doc_xyz
```

When combined with RBAC permissions, users can access:
- All records matching their RBAC scopes (e.g., `:own`, `:published`)
- Plus specific instances from instance permissions

The filters are combined with OR logic:
`(owner_id == actor.id) OR (id IN ["doc_abc", "doc_xyz"])`

### Legacy Format Support

For backward compatibility, shorter formats are supported but **use with caution**:

| Input | Parsed As | Notes |
|-------|-----------|-------|
| `"blog:read:all"` | `blog:*:read:all` | Safe - 3rd part is clearly a scope |
| `"blog:read"` | `blog:*:read:` | Safe - 2-part format |
| `"blog:post123:read"` | `blog:*:post123:read` | Ambiguous! `post123` becomes action |

**Recommendation:** Always use the full 4-part format to avoid ambiguity:

```elixir
# RBAC permissions
"blog:*:read:all"       # Explicit 4-part format (recommended)
"blog:read:all"         # Legacy 3-part format (works but discouraged)

# Instance permissions
"blog:post123:read:"    # Explicit instance permission (recommended)
```

### Deny-Wins Pattern

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

### Scope Combination Rules

#### Multiple Permissions = OR

When an actor has **multiple permissions** with different scopes for the same action,
they are combined with **OR**:

```elixir
# Actor has both permissions:
["post:*:read:own", "post:*:read:published"]

# Result filter: (author_id == actor.id) OR (status == :published)
# Actor can see their own posts AND all published posts
```

#### Scope Inheritance = AND

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

### Example: Date-Based Scopes

You can use SQL fragments for temporal filtering:

```elixir
# Records created today only
scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))

# Combined with ownership
scope :own_today, [:own], expr(fragment("DATE(inserted_at) = CURRENT_DATE"))
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

#### Multi-Tenancy: Two Approaches

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

### Relational Scopes (`exists()`)

You can use `exists()` in scope expressions for relationship-based filtering:

```elixir
ash_grant do
  scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))
  scope :own_in_team, expr(author_id == ^actor(:id) and exists(team.memberships, user_id == ^actor(:id)))
end
```

> **Important: `exists()` scopes and write actions**
>
> `exists()` is only fully enforced for **read** actions, where `FilterCheck` converts it
> to a SQL EXISTS subquery. For **write** actions (create, update, destroy), `Check`
> evaluates scopes in-memory and cannot resolve `exists()` — the relational condition
> is replaced with `true`. Attribute-based conditions in the same scope are still checked.
>
> For example, with `expr(author_id == ^actor(:id) and exists(team.memberships, ...))`:
> - **Read**: Both `author_id` check and `exists()` are enforced as SQL
> - **Write**: Only `author_id` check is enforced; `exists()` is treated as `true`
>
> A compile-time warning is emitted when `exists()` scopes are detected on resources
> with write policies enabled. If you need relational authorization for writes, use a
> custom `Ash.Policy.Check` that queries the database, or move the check to a
> change/validation on the action.

### Business Scope Examples

AshGrant supports a wide variety of business scenarios. Here are common patterns:

#### Status-Based Workflow

```elixir
ash_grant do
  scope :all, true
  scope :draft, expr(status == :draft)
  scope :pending_review, expr(status == :pending_review)
  scope :approved, expr(status == :approved)
  scope :editable, expr(status in [:draft, :pending_review])
end
```

#### Security Classification

Hierarchical access levels:

```elixir
ash_grant do
  scope :public, expr(classification == :public)
  scope :internal, expr(classification in [:public, :internal])
  scope :confidential, expr(classification in [:public, :internal, :confidential])
  scope :top_secret, true  # Can see all
end
```

#### Transaction Limits

Numeric comparisons for amount-based authorization:

```elixir
ash_grant do
  scope :small_amount, expr(amount < 1000)
  scope :medium_amount, expr(amount < 10000)
  scope :large_amount, expr(amount < 100000)
  scope :unlimited, true
end
```

#### Multi-Tenant with Inheritance

Combined scopes using inheritance:

```elixir
ash_grant do
  scope :tenant, expr(tenant_id == ^actor(:tenant_id))
  scope :tenant_active, [:tenant], expr(status == :active)
  scope :tenant_own, [:tenant], expr(created_by_id == ^actor(:id))
end
```

#### Time/Period Based

Temporal filtering:

```elixir
ash_grant do
  scope :current_period, expr(period_id == ^actor(:current_period_id))
  scope :open_periods, expr(period_status == :open)
  scope :this_fiscal_year, expr(fiscal_year == ^actor(:fiscal_year))
end
```

#### Geographic/Territory

List membership for territory assignments:

```elixir
ash_grant do
  scope :same_region, expr(region_id == ^actor(:region_id))
  scope :assigned_territories, expr(territory_id in ^actor(:territory_ids))
  scope :my_accounts, expr(account_manager_id == ^actor(:id))
end
```

## Field-Level Permissions

AshGrant supports column-level read authorization through **field groups**. Field groups control which fields are visible based on the actor's permissions, using Ash's native `field_policies` system.

### Field Group DSL

Define field groups with optional inheritance:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :all, true

  # Root group — no inheritance
  field_group :public, [:name, :department, :position]

  # Inherits all fields from :public, adds phone and address
  field_group :sensitive, [:public], [:phone, :address]

  # Inherits all fields from :sensitive (which includes :public)
  field_group :confidential, [:sensitive], [:salary, :email]
end
```

### Permission Strings with Field Groups

The 5th part of the permission string specifies the field group:

```elixir
"employee:*:read:all:public"         # See name, department, position only
"employee:*:read:all:sensitive"      # See public + phone, address
"employee:*:read:all:confidential"   # See all fields
"employee:*:read:all"               # No field_group → all fields visible
```

Fields not in the actor's field group are replaced with `%Ash.ForbiddenField{}`.

### Mode A: Manual Field Policies

Write Ash `field_policies` using `AshGrant.field_check/1`:

```elixir
field_policies do
  field_policy [:salary, :email] do
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

### Mode B: Auto-Generated Field Policies

Set `default_field_policies: true` to auto-generate field policies from field group definitions:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true
  default_field_policies true  # Auto-generates field_policies from field_groups

  scope :all, true

  field_group :public, [:name, :department, :position]
  field_group :sensitive, [:public], [:phone, :address]
  field_group :confidential, [:sensitive], [:salary, :email]
end
```

This auto-generates equivalent field policies with a catch-all `field_policy :*` that allows non-grouped fields.

### Field Group Inheritance

Inheritance follows a DAG (directed acyclic graph) — a child group includes all parent fields:

```
:public       → [:name, :department, :position]
:sensitive    → [:name, :department, :position, :phone, :address]
:confidential → [:name, :department, :position, :phone, :address, :salary, :email]
```

An actor with `confidential` permission can see everything that `sensitive` and `public` can see, plus their own fields.

### Field Masking

Instead of hiding fields entirely, you can show masked values:

```elixir
field_group :sensitive, [:public], [:phone, :address],
  mask: [:phone, :address],
  mask_with: fn value, _field ->
    if is_binary(value), do: String.replace(value, ~r/./, "*"), else: "***"
  end
```

**Masking rules:**
- Masking is **not inherited** — a higher-level group sees original values
- **Allow-wins**: if an actor has both a masking group and a non-masking group for the same field, the field is unmasked
- Actors with 4-part permissions (no field_group) see all fields unmasked

**Example behavior:**

| Actor Permission | phone | salary |
|-----------------|-------|--------|
| `...:public` | `%Ash.ForbiddenField{}` | `%Ash.ForbiddenField{}` |
| `...:sensitive` (with masking) | `"*************"` | `%Ash.ForbiddenField{}` |
| `...:confidential` | `"010-1234-5678"` | `80000` |
| `...` (4-part, no field_group) | `"010-1234-5678"` | `80000` |

## Check Types

### `filter_check/1` - For Read Actions

Returns a filter expression that limits query results to accessible records.
All scope types including `exists()` are fully supported (converted to SQL).

```elixir
policy action_type(:read) do
  authorize_if AshGrant.filter_check()
end
```

### `check/1` - For Write Actions

Returns `true` or `false` based on whether the actor has permission.
Scopes are evaluated in-memory against the target record or changeset attributes.

> **Note:** Scopes using `exists()` cannot be evaluated in-memory — the relational
> condition is replaced with `true`. Attribute-based conditions are still enforced.
> See [Relational Scopes](#relational-scopes-exists) for details.

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
  resource_name "custom_name"             # Optional: defaults to module name (e.g., MyApp.Blog.Post → "post")

  # Inline scopes
  scope :all, true
  scope :own, expr(owner_id == ^actor(:id))
end
```

| Option | Type | Description |
|--------|------|-------------|
| `resolver` | module or function | **Required.** Resolves permissions for actors |
| `default_policies` | boolean or atom | Auto-generate policies: `true`, `:all`, `:read`, or `:write` |
| `default_field_policies` | boolean | Auto-generate `field_policies` from `field_group` definitions |
| `resource_name` | string | Resource name for permission matching. Default: derived from module name (last segment, snake_cased). `MyApp.Blog.Post` → `"post"`, `MyApp.CustomerOrder` → `"customer_order"` |

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

### Combining default_policies with Custom Policies

`default_policies` **adds** policies, it doesn't replace existing ones.
You can combine them:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true  # Adds filter_check for read, check for write
end

policies do
  # This bypass runs BEFORE the default policies
  bypass actor_attribute_equals(:role, :admin) do
    authorize_if always()
  end

  # You can add more custom policies too
  policy action(:special_action) do
    authorize_if MyCustomCheck
  end
end
```

**Evaluation order:**

1. Bypass policies (if any)
2. Custom policies defined in `policies do`
3. Default policies from `default_policies: true`

### Legacy ScopeResolver

The `scope_resolver` option is deprecated. If configured alongside inline scopes, inline scope DSL is checked first and `scope_resolver` acts as a fallback for scopes not defined inline. An error is raised if a scope is found in neither. Migrate all scopes to inline `scope` definitions.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope_resolver MyApp.LegacyScopeResolver  # Deprecated fallback

  # Inline scopes take priority
  scope :all, true
  scope :own, expr(author_id == ^actor(:id))
  # :legacy_scope will fall back to scope_resolver
end
```

## Architecture

```
                    Ash Policy Check
                          |
            +-------------+-------------+-------------+
            |                           |             |
      +-----v-----+              +------v------+  +--v----------+
      |  Check    |              | FilterCheck |  | FieldCheck  |
      | (writes)  |              |  (reads)    |  | (fields)    |
      +-----+-----+              +------+------+  +--+----------+
            |                           |             |
            +-----------+---------------+-------------+
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
            | Scope DSL / Field     |
            | Groups / Resolver     |
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

  scope :all, true, description: "All records without restriction"
  scope :own, expr(author_id == ^actor(:id)), description: "Records owned by the current user"
  scope :published, expr(status == :published), description: "Published records visible to everyone"
end
```

Access scope descriptions programmatically:

```elixir
AshGrant.Info.scope_description(MyApp.Post, :own)
# => "Records owned by the current user"
```

## Permission Introspection

The `AshGrant.Introspect` module provides runtime helpers for querying permissions:

### Admin UI: What can this user do?

```elixir
AshGrant.Introspect.actor_permissions(Post, current_user)
# => [
#   %{action: "read", allowed: true, scope: "all", denied: false, instance_ids: nil, field_groups: []},
#   %{action: "update", allowed: true, scope: "own", denied: false, instance_ids: nil, field_groups: []},
#   %{action: "destroy", allowed: false, scope: nil, denied: false, instance_ids: nil, field_groups: []}
# ]
```

### Permission Management: What permissions exist?

```elixir
AshGrant.Introspect.available_permissions(Post)
# => [
#   %{permission_string: "post:*:read:all", action: "read", scope: "all", scope_description: "All records", field_group: nil},
#   %{permission_string: "post:*:read:own", action: "read", scope: "own", scope_description: "Own records", field_group: nil},
#   ...
# ]
```

> **Note**: `available_permissions/1` requires inline scope definitions in the DSL.
> Resources using `scope_resolver` will return an empty list.

### Debugging: Can user do this action?

```elixir
AshGrant.Introspect.can?(Post, :read, user)
# => {:allow, %{scope: "all", instance_ids: nil, field_groups: []}}

AshGrant.Introspect.can?(Post, :destroy, user)
# => {:deny, %{reason: :no_permission}}
```

### API Response: What actions are available?

```elixir
# Simple list
AshGrant.Introspect.allowed_actions(Post, user)
# => [:read, :create, :update]

# With details
AshGrant.Introspect.allowed_actions(Post, user, detailed: true)
# => [
#   %{action: :read, scope: "all", instance_ids: nil, field_groups: []},
#   %{action: :create, scope: "all", instance_ids: nil, field_groups: []},
#   %{action: :update, scope: "own", instance_ids: nil, field_groups: []}
# ]
```

### Raw Permission Access

```elixir
AshGrant.Introspect.permissions_for(Post, user)
# => ["post:*:read:all", "post:*:update:own", "post:*:create:all"]
```

### With Context

All functions accept a `:context` option for passing additional resolver context:

```elixir
AshGrant.Introspect.actor_permissions(Post, user, context: %{tenant: tenant_id})
```

## SAT Solver Optimization

AshGrant implements Ash's optional policy check callbacks to help the SAT solver
make smarter authorization decisions:

| Callback | Purpose |
|----------|---------|
| `simplify/2` | Decomposes checks into simpler SAT expressions |
| `implies?/3` | Determines if one check guarantees another is true |
| `conflicts?/3` | Determines if two checks are mutually exclusive |

These callbacks enable the authorizer to reach decisions with fewer variables
in conditions, potentially short-circuiting evaluation before loading data.

**Current implementation:**

- `simplify/2` returns the ref unchanged (permissions are runtime-resolved)
- `implies?/3` returns `true` when check refs have identical module and options
- `conflicts?/3` returns `false` (deny-wins is handled at evaluation time)

This provides a foundation for future optimizations while maintaining correct
behavior with Ash's policy system.

## Policy Configuration Testing

AshGrant provides a DSL-based testing framework for verifying policy configurations without requiring a database. This tests **policy configuration**, not data - no database records needed.

### Resource Setup

Policy tests verify how your resolver converts roles to permissions. Use the `Post` resource from the [Quick Start](#quick-start) section above, or any resource with an `ash_grant` block configured.

### DSL-Based Tests

Write policy tests to verify the resolver and scope configuration:

```elixir
defmodule MyApp.PolicyTests.PostPolicyTest do
  use AshGrant.PolicyTest

  resource MyApp.Post

  actor :admin, %{role: :admin}
  actor :editor, %{role: :editor, id: "editor_001"}
  actor :viewer, %{role: :viewer}

  describe "read access" do
    test "editor can read all posts" do
      assert_can :editor, :read
    end

    test "viewer can read published posts" do
      assert_can :viewer, :read, %{status: :published}
    end

    test "viewer cannot read drafts" do
      assert_cannot :viewer, :read, %{status: :draft}
    end
  end

  describe "write access" do
    test "editor can update own posts" do
      assert_can :editor, :update, %{author_id: "editor_001"}
    end

    test "editor cannot update others posts" do
      assert_cannot :editor, :update, %{author_id: "other_user"}
    end

    test "viewer cannot update any posts" do
      assert_cannot :viewer, :update
    end
  end
end
```

### Assertion Macros

| Macro | Description |
|-------|-------------|
| `assert_can(actor, action)` | Actor can perform action |
| `assert_can(actor, action, record)` | Actor can access specific record |
| `assert_cannot(actor, action)` | Actor cannot perform action |
| `assert_cannot(actor, action, record)` | Actor cannot access specific record |

Action can be specified as:
- Atom: `:read` (shorthand for `action: :read`)
- Keyword: `action: :approve` (specific action name)
- Keyword: `action_type: :update` (all actions of type)

### YAML Format

Policy tests can also be written in YAML for non-developers or interchange:

```yaml
resource: MyApp.Post

actors:
  editor:
    role: editor
    id: "editor_001"
  viewer:
    role: viewer

tests:
  - name: "editor can read all posts"
    assert_can:
      actor: editor
      action: read

  - name: "viewer can read published posts"
    assert_can:
      actor: viewer
      action: read
      record:
        status: published

  - name: "viewer cannot read drafts"
    assert_cannot:
      actor: viewer
      action: read
      record:
        status: draft

  - name: "editor can update own posts"
    assert_can:
      actor: editor
      action: update
      record:
        author_id: "editor_001"

  - name: "editor cannot update others posts"
    assert_cannot:
      actor: editor
      action: update
      record:
        author_id: "other_user"
```

### Mix Tasks

**Run policy tests:**

```bash
# Run DSL tests
mix ash_grant.verify test/policy_tests/

# Run YAML tests
mix ash_grant.verify priv/policy_tests/document.yaml

# Verbose output
mix ash_grant.verify test/policy_tests/ --verbose
```

**Export policies:**

```bash
# Export to YAML
mix ash_grant.export MyApp.Document --format=yaml

# Export to Mermaid diagram
mix ash_grant.export MyApp.Document --format=mermaid

# Export to Markdown documentation
mix ash_grant.export MyApp.Document --format=markdown

# Export to file
mix ash_grant.export MyApp.Document --format=markdown --output=docs/document.md
```

**Import YAML to DSL:**

```bash
# Generate DSL code from YAML (output to stdout)
mix ash_grant.import priv/policy_tests/document.yaml

# Generate and write to file
mix ash_grant.import priv/policy_tests/document.yaml --output=test/policy_tests/document_test.exs
```

### Running Policy Tests

Use the `AshGrant.PolicyTest.Runner` module programmatically:

```elixir
# Run a single module
results = AshGrant.PolicyTest.Runner.run_module(MyApp.PolicyTests.DocumentPolicyTest)

# Run all policy test modules
summary = AshGrant.PolicyTest.Runner.run_all()
# => %{passed: 10, failed: 0, results: [...]}

# Run specific modules
summary = AshGrant.PolicyTest.Runner.run_all(modules: [DocumentPolicyTest, PostPolicyTest])
```

### Dependencies

To use YAML format, add `yaml_elixir` to your dependencies:

```elixir
def deps do
  [
    {:yaml_elixir, "~> 2.9"}
  ]
end
```

## API Reference

### Modules

| Module | Description |
|--------|-------------|
| `AshGrant` | Main extension module with `check/1`, `filter_check/1`, `field_check/1`, and `explain/4` |
| `AshGrant.Introspect` | Runtime permission introspection for UIs and APIs |
| `AshGrant.Explanation` | Authorization decision explanation struct |
| `AshGrant.Explainer` | Builds detailed authorization explanations |
| `AshGrant.Permission` | Permission parsing and matching (4-part and 5-part formats) |
| `AshGrant.PermissionInput` | Permission input with metadata for debugging |
| `AshGrant.Permissionable` | Protocol for converting custom structs to permissions |
| `AshGrant.Evaluator` | Deny-wins permission evaluation with field group support |
| `AshGrant.PermissionResolver` | Behaviour for resolving permissions |
| `AshGrant.ScopeResolver` | Behaviour for scope resolution (legacy) |
| `AshGrant.Check` | SimpleCheck for write actions (with SAT solver callbacks) |
| `AshGrant.FilterCheck` | FilterCheck for read actions (with SAT solver callbacks) |
| `AshGrant.FieldCheck` | SimpleCheck for field-level authorization in `field_policies` |
| `AshGrant.Info` | DSL introspection helpers (scopes, field groups, configuration) |
| `AshGrant.PolicyTest` | Policy configuration testing DSL |
| `AshGrant.PolicyTest.Runner` | Test runner for policy tests |
| `AshGrant.PolicyExport` | Export policies to various formats |

## Testing

AshGrant includes comprehensive tests using `Ash.Generator` for fixture generation:

```bash
mix test
```

The test suite covers:

- **Permission parsing** - All format variants (4-part and 5-part) and edge cases
- **Evaluator** - Deny-wins semantics with property-based tests
- **Field groups** - Column-level authorization, inheritance, masking, integration
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

## Disclosure

  I've been a developer for about six years. I became interested in Elixir, Phoenix, and Ash a couple of years ago, but only started actually building with
  them about four months ago. This library was born out of my own needs, and honestly, my skills in this ecosystem aren't at the level where I'd normally
  attempt building something like this.

  Most of AshGrant was developed through TDD with Claude Code—I described what I needed, Claude Code wrote the tests and implementation, and I reviewed the
  results. I treated it like any third-party library: if the tests pass and the code looks reasonable, I use it. I haven't read every line of code in detail,
  so I can't guarantee everything works perfectly.

  I'm using this in production because I need it now, but please consider this more as a **proof of concept**—a proposal for how authorization could be handled
   in Ash. I'm sharing this publicly in hopes that it can be a starting point. If others find it useful and want to contribute, we could build something better
   together.

  If you have suggestions or find issues, please feel free to open an issue or submit a PR—contributions are very welcome.

  What made this possible is how exceptionally well-documented Elixir and Ash are. The clear abstractions—DSLs, Domains, Resources, Extensions—gave me a
  precise vocabulary to communicate my requirements to an LLM. These well-defined concepts provided both the courage to start and the foundation to actually
  ship something I use in production.

  I'm deeply grateful to Zach for creating Ash Framework, the Ash Core Team, all the contributors, and the broader Elixir community. We have something special
  here.

## License

MIT License - see [LICENSE](LICENSE) for details.

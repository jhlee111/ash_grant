# Permissions

AshGrant uses an Apache Shiro-inspired permission string format with deny-wins semantics.

## Permission String Format

```
[!]resource:instance_id:action:scope[:field_group]
```

| Component | Description | Examples |
|-----------|-------------|----------|
| `!` | Optional deny prefix | `!blog:*:delete:always` |
| resource | Resource type or `*` | `blog`, `post`, `*` |
| instance_id | Resource instance or `*` | `*`, `post_abc123xyz789ab` |
| action | Action name or wildcard | `read`, `*`, `read*` |
| scope | Access scope | `all`, `own`, `published`, or empty |
| field_group | Optional column-level group | `public`, `sensitive`, `confidential` |

The 5th part (`field_group`) is optional. When omitted (4-part format), all fields are visible.
When present, only fields in the named group (and its inherited parents) are accessible.

## Wildcard Matching Rules

| Component | `*` (all) | `type*` (action type) | Exact match |
|-----------|-----------|----------------------|-------------|
| resource | Yes | No | Yes |
| instance_id | Yes | No | Yes |
| action | Yes | Yes | Yes |
| scope | No | No | Yes |

**Examples:**

```elixir
"*:*:read:always"       # All resources, read action (exact name match)
"blog:*:read*:always"   # All :read-type actions on blog (type match)
"blog:*:read:always"    # Only the action named "read" on blog (exact match)
```

### Action Type Wildcards vs Exact Action Names

AshGrant has two distinct action matching modes:

- **`read`** (exact) — matches the action **named** `read`, regardless of its action type
- **`read*`** (type wildcard) — matches any action whose **action type** is `:read`

These are completely separate. `read*` does **not** match by string prefix — it only
matches by action type.

| Permission | Matches | Why |
|------------|---------|-----|
| `post:*:read*:always` | `:list`, `:search`, `:get_by_id` | All actions with `type: :read` |
| `post:*:update*:always` | `:publish`, `:approve`, `:archive` | All actions with `type: :update` |
| `post:*:read:always` | `:read` only | Exact action name match |

This means a permission like `post:*:read*:always` grants access to **all read-type actions**
on the resource, including custom ones like `:search` or `:export` if they are defined
with `type: :read`.

> **Warning:** Be careful in workflows where different read actions should have different
> access levels. For example, if `:list` shows summaries but `:read` shows full details,
> using `read*` would grant access to both. Use exact action names instead:
> `post:*:list:always` and `post:*:read:own`.

### Generic Actions

Generic actions (Ash actions with `type: :action`) must be authorized by their
**specific action name**. Type wildcards do not apply — each generic action is
individually unique (one might send email, another processes a payment), so
blanket type-level access is not supported.

| Permission | Matches | Why |
|------------|---------|-----|
| `service:*:ping:always` | `:ping` only | Exact action name match |
| `service:*:*:always` | All actions including generic | Universal wildcard |
| `service:*:check_status:always` | `:check_status` only | Exact action name match |

```elixir
# Grant access to specific generic actions
["service:*:ping:always", "service:*:check_status:always"]

# Or use the universal wildcard for admin access
["service:*:*:always"]
```

## RBAC Permissions (instance_id = `*`)

```elixir
"blog:*:read:always"           # Read all blogs
"blog:*:read:published"     # Read only published blogs
"blog:*:update:own"         # Update own blogs only
"blog:*:*:always"              # All actions on all blogs
"*:*:read:always"              # Read all resources
"blog:*:read*:always"          # All read-type actions
"!blog:*:delete:always"        # DENY delete on all blogs
```

## Instance Permissions (specific instance_id)

For sharing specific resources (like Google Docs):

```elixir
"blog:post_abc123xyz789ab:read:"     # Read specific post
"blog:post_abc123xyz789ab:*:"        # Full access to specific post
"!blog:post_abc123xyz789ab:delete:"  # DENY delete on specific post
```

Instance permissions have an empty scope (trailing colon) because the permission
is already scoped to a specific instance.

> **Boundary note:** Instance permissions match against the resource's own key field only
> (`:id` by default, or the field specified by `instance_key`). They do **not** automatically
> propagate to child resources. For example, `"feed:feed_abc:read:"` grants access to
> the Feed record itself, but not to Posts belonging to that feed. Use
> [`scope_through`](#scope-through-parent-child-propagation) to propagate parent instance
> permissions to child resources.

### Instance Permissions with Scopes (ABAC)

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

### Instance Permission Read Example

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

### Combining RBAC and Instance Permissions

When an actor has both RBAC permissions (with scopes) and instance permissions,
the filters are combined with **OR** logic. This means users can access:

- All records matching their RBAC scopes (e.g., `:own`, `:published`)
- **Plus** specific instances from instance permissions

```elixir
# Actor has:
# - "document:*:read:own"           (RBAC — read own documents)
# - "document:doc_abc:read:"        (Instance — read shared doc)
# - "document:doc_xyz:read:"        (Instance — read shared doc)

# Result filter:
# (owner_id == actor.id) OR (id IN ["doc_abc", "doc_xyz"])

# The actor can see all their own documents AND the two shared ones
```

This is a common pattern for document sharing: users always see their own documents,
plus any documents explicitly shared with them via instance permissions.

### Instance Key

By default, instance permissions match against the `:id` (primary key) field.
Use `instance_key` to match against a different field:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  instance_key :feed_id  # Match against feed_id instead of id

  scope :always, true
end
```

With `instance_key :feed_id`, the permission `"feed:feed_abc:read:"` generates
`WHERE feed_id IN ('feed_abc')` instead of `WHERE id IN ('feed_abc')`.

### Scope Through (Parent-Child Propagation)

Use `scope_through` to propagate a parent resource's instance permissions to
child resources via a `belongs_to` relationship:

```elixir
defmodule MyApp.Post do
  use Ash.Resource, extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    default_policies true

    scope :always, true
    scope :own, expr(author_id == ^actor(:id))

    # Posts inherit Feed's instance permissions via :feed relationship
    scope_through :feed
  end

  relationships do
    belongs_to :feed, MyApp.Feed
  end
end
```

When a user has `"feed:feed_abc:read:"`, they can read all posts where
`feed_id == "feed_abc"`. This works for reads (FilterCheck), writes (Check),
and CanPerform calculations. Parent instance filters are combined with RBAC
scopes using OR logic.

Options:
- `scope_through :feed` — infer parent resource from relationship
- `scope_through :feed, actions: [:read, :update]` — limit to specific actions

## Legacy Format Support

For backward compatibility, shorter formats are supported but **use with caution**:

| Input | Parsed As | Notes |
|-------|-----------|-------|
| `"blog:read:always"` | `blog:*:read:always` | Safe - 3rd part is clearly a scope |
| `"blog:read"` | `blog:*:read:` | Safe - 2-part format |
| `"blog:post123:read"` | `blog:*:post123:read` | Ambiguous! `post123` becomes action |

**Recommendation:** Always use the full 4-part format to avoid ambiguity:

```elixir
# RBAC permissions
"blog:*:read:always"       # Explicit 4-part format (recommended)
"blog:read:always"         # Legacy 3-part format (works but discouraged)

# Instance permissions
"blog:post123:read:"    # Explicit instance permission (recommended)
```

## Deny-Wins Pattern

When both allow and deny rules match, deny always takes precedence:

```elixir
permissions = [
  "blog:*:*:always",           # Allow all blog actions
  "!blog:*:delete:always"      # Deny delete
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

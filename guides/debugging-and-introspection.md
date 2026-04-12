# Debugging & Introspection

AshGrant provides tools for understanding authorization decisions and querying
permissions at runtime.

## Debugging with `explain/4`

Use `AshGrant.explain/4` to understand why authorization succeeded or failed:

```elixir
# Get detailed explanation
result = AshGrant.explain(MyApp.Post, :read, actor)

# Check the decision
result.decision  # => :allow or :deny

# See matching permissions with metadata
result.matching_permissions
# => [%{permission: "post:*:read:always", description: "Read all posts", source: "editor_role", ...}]

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
  • post:*:read:always [scope: always - All records without restriction] (from: editor_role)
    └─ Read all posts

Scope Filter: true (no filtering)
───────────────────────────────────────────────────────────────────
```

## Dual Read/Write Scope (`write:` Option)

Scopes with `exists()` or dot-paths work automatically for both reads and writes via
DB query fallback. The `write:` option is an optional override for explicit control:

| `write:` value | Strategy | Behavior |
|----------------|----------|----------|
| _(omitted, no relationships)_ | In-memory | Evaluates filter in-memory (default) |
| _(omitted, has relationships)_ | DB query | Queries DB with read scope (automatic) |
| `write: expr(...)` | In-memory | Use this expression for writes (overrides DB query) |
| `write: false` | Deny | Explicitly deny all writes with this scope |
| `write: true` | Allow | Allow all writes with this scope (no filtering) |

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :always, true

  # Relational scope — DB query fallback handles writes automatically
  scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))

  # Explicitly deny writes
  scope :org_member, expr(exists(org.users, id == ^actor(:id))),
    write: false

  # Explicit in-memory override (avoids DB round-trip)
  scope :same_org, expr(exists(org.users, id == ^actor(:id))),
    write: expr(org_id == ^actor(:org_id))

  # Simple scopes — in-memory evaluation, no write: needed
  scope :own, expr(author_id == ^actor(:id))
end
```

**Inheritance:** Child scopes inherit their parent's `write:` expression. If a parent
has `write: false`, it propagates to all children:

```elixir
scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id))),
  write: false
scope :team_editor, [:team_member], expr(role == :editor)
# team_editor inherits write: false — writes are denied
```

**Resolution functions:**
- `AshGrant.Info.resolve_scope_filter/3` — always returns the read (filter) expression
- `AshGrant.Info.resolve_write_scope_filter/3` — returns `write:` expression if set, otherwise falls back to `filter`

## Scope Descriptions

Add descriptions to scopes for better debugging output:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :always, true, description: "All records without restriction"
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
#   %{permission_string: "post:*:read:always", action: "read", scope: "all", scope_description: "All records", field_group: nil},
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
# => ["post:*:read:always", "post:*:update:own", "post:*:create:always"]
```

### With Context

All functions accept a `:context` option for passing additional resolver context:

```elixir
AshGrant.Introspect.actor_permissions(Post, user, context: %{tenant: tenant_id})
```

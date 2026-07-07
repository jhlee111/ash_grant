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

## Read vs write scope evaluation

Scopes with `exists()` or dot-paths work for both reads and writes automatically:

- **Read**: `FilterCheck` lowers the expression to SQL.
- **Write**: `Check` evaluates it in memory where possible; for scopes with
  relationship references it falls back to a DB query.

For multi-hop write authorization (e.g., `refund.order.center_id in actor_units`),
prefer argument-based scopes — they keep the scope expression in-memory-evaluable
and push relationship traversal into the resource's own change pipeline:

```elixir
ash_grant do
  scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
  resolve_argument :center_id, from_path: [:order, :center_id]
end
```

See the [Argument-Based Scope guide](argument-based-scope.md) for the full pattern.

**Resolution functions:**
- `AshGrant.Info.resolve_scope_filter/3` — resolved read filter (inheritance applied)
- `AshGrant.Info.resolve_write_scope_filter/3` — resolved write filter (inheritance applied; respects the deprecated `write:` override for backward compatibility — see below)

### `write:` option (deprecated)

The `write:` option was introduced as an escape hatch when the main `filter`
could not be evaluated in memory on write actions. It is **deprecated as of
0.14** — prefer argument-based scopes + `resolve_argument` for multi-hop
cases, or use a separate scope name for read-only semantics.

Using `write:` still works but emits a compile-time deprecation warning.

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
# => {:allow, %{scope: "all", scopes: ["all"], instance_ids: nil, field_groups: []}}

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

## Identifier-Based Introspection

The functions above all take a hydrated actor struct. External tools —
admin dashboards, CLI commands, LLM agents, webhook handlers — often
have only an **actor ID** plus string keys for the resource and action.
The identifier-based variants take strings/IDs and do the lookup work
themselves.

**Provisional (v0.15):** signatures may tighten in a minor release. See
[Public API Contract](public-api-contract.md) for stability tiers.

### Opt in: implement `load_actor/1` on your resolver

The identifier-based functions call your resolver module's optional
`load_actor/1` callback to turn an ID into an actor. Implementing it is
how a resolver declares it can be driven by ID:

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(actor, _context), do: actor.permissions

  @impl true
  def load_actor(user_id) do
    case MyApp.Accounts.get_user(user_id) do
      nil -> :error
      user -> {:ok, user}
    end
  end
end
```

Existing resolvers without `load_actor/1` keep working — the
identifier-based functions return
`{:error, :actor_loader_not_implemented}` and the rest of the API is
unchanged.

### `explain_by_identifier/1`

Resolves the resource by key, loads the actor, and delegates to
`AshGrant.explain/4`:

```elixir
AshGrant.Introspect.explain_by_identifier(
  actor_id: "user_1",
  resource_key: "post",    # matches AshGrant.Info.resource_name/1
  action: :read,
  context: %{tenant: "acme"}  # optional
)
# => {:ok, %AshGrant.Explanation{decision: :allow, ...}}
```

### `can_by_identifier/3`

```elixir
AshGrant.Introspect.can_by_identifier("user_1", "post", :read)
# => {:allow, %{scope: "always", scopes: ["always"], instance_ids: nil, field_groups: []}}

AshGrant.Introspect.can_by_identifier("user_1", "post", :destroy)
# => {:deny, %{reason: :no_permission}}
```

### `actor_permissions_by_id/2`

```elixir
AshGrant.Introspect.actor_permissions_by_id("user_1", "post")
# => {:ok, [%{action: "read", allowed: true, ...}, ...]}
```

### Error returns

All three never raise for predictable lookup failures. They return:

| Return | Meaning |
|---|---|
| `{:error, :unknown_resource}` | No registered resource has `resource_key` as its `resource_name` |
| `{:error, :actor_loader_not_implemented}` | Resolver is an anonymous function, or the module doesn't export `load_actor/1` |
| `{:error, :actor_not_found}` | Resolver's `load_actor/1` returned `:error` |

### CLI: `mix ash_grant.explain`

A thin wrapper around `explain_by_identifier/1` for shell scripts and
CI checks:

```
mix ash_grant.explain --actor USER_ID --resource RESOURCE_KEY --action ACTION \
  [--format text|json] [--context '<json>']
```

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Explanation produced (allow or deny both exit 0) |
| `1` | Lookup failure (unknown resource / actor loader / actor not found) |
| `2` | Usage error (bad flag, malformed `--context`) |

## Stringifying Scope Expressions

**Provisional (v0.15).**

Ash's default expression inspect is readable but uses internal
references like `{:_actor, :id}` instead of the DSL-facing
`^actor(:id)`. `AshGrant.ExprStringify.to_string/1` produces the
human-facing form — the same form users write in their `ash_grant do`
blocks.

```elixir
expr = AshGrant.Info.resolve_scope_filter(MyApp.Post, :own, %{})
AshGrant.ExprStringify.to_string(expr)
# => "author_id == ^actor(:id)"

AshGrant.ExprStringify.to_string(true)   # => "true"
AshGrant.ExprStringify.to_string(nil)    # => "nil"
```

Mappings:

| Internal term | Stringified |
|---|---|
| `{:_actor, :id}` | `^actor(:id)` |
| `{:_context, :reference_date}` | `^context(:reference_date)` |
| `:_tenant` | `^tenant()` |

Contract:

- Always returns a binary.
- Never raises — unknown terms fall back to `inspect/1`.
- Display-only. The output is *not* round-trippable back into an
  expression.

The same function populates `Explanation.scope_filter_string`, so JSON
consumers (LLM tools, dashboards) always receive a printable form
without having to carry the raw AST.

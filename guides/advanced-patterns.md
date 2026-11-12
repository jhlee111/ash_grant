# Advanced Patterns

Scopes with `^actor(:id)` or plain attribute comparisons cover most
applications. Real projects eventually hit authorization questions that
require information the record doesn't hold directly:

- *"Can this user refund this order, given that the authority lives on the
  order's organizational unit — not on the refund itself?"*
- *"A workspace is shared with a user; can they see comments on posts in
  that workspace, without re-granting comments individually?"*
- *"Above applies, but with an extra attribute filter (`status == :open`)
  layered on the parent-shared ones."*

Two entities handle these, and most real apps end up needing both:

- **`resolve_argument`** — the record computes a value from its own
  relationships and exposes it as an action argument, so scopes can
  compare against `^arg(:name)` in-memory.
- **`scope_through`** — parent-resource instance permissions
  (`"workspace:ws_abc:read:"`) automatically propagate to a child via a
  `belongs_to` relationship.

This guide pulls them together with end-to-end recipes. For the full
rationale and internals of `resolve_argument`, see the
[Argument-Based Scope](argument-based-scope.md) guide.

> **Prerequisite:** Familiarity with [Scopes](scopes.md) and
> [Permissions](permissions.md).

## When to reach for which

| Situation | Use |
|---|---|
| Authorization value is an FK on the record (`center_id`) | Direct attribute scope: `expr(center_id in ^actor(:own_units))` |
| Authorization value lives on a related record (`order.center_id`), write action | `resolve_argument` |
| Authorization value lives on a related record, read-only | Relational scope (`expr(order.center_id in ...)`) is fine — lowers to SQL |
| Parent record is *individually shared* with an actor (Google-Docs-style) and children should follow | `scope_through` |
| Both: parent is shared *and* the child has an additional condition | `scope_through` + RBAC scope (combined via OR) |
| Both: value is relation-derived *and* parent is shared | `resolve_argument` + `scope_through` |

## Recipe 1: Multi-hop write authorization with `resolve_argument`

**Problem.** A `Refund` has `belongs_to :order`. An actor can refund an
order only when the order's `center_id` is one of the units they manage.
Using `expr(order.center_id in ^actor(:own_org_unit_ids))` works on reads
but forces the write-side DB-query fallback and has rough edges with
composite scopes and FK-changing updates.

**Solution.** Declare the scope against an argument, and let the resource
populate the argument from its own `:order` relationship.

```elixir
defmodule MyApp.Orders.Refund do
  use Ash.Resource,
    domain: MyApp.Orders,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    default_policies true

    scope :always, true
    scope :by_own_author, expr(author_id == ^actor(:id))

    # Argument-based scope — no relationship traversal in the expression
    scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))

    # Populates :center_id from the record's own :order FK before auth runs.
    # The injected change is lazy: it only loads :order when an in-play
    # permission uses a scope that references ^arg(:center_id).
    resolve_argument :center_id, from_path: [:order, :center_id]
  end

  relationships do
    belongs_to :order, MyApp.Orders.Order, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy]
    create :create, do: accept [:author_id, :total_amount, :order_id]

    update :update do
      accept [:total_amount]
      require_atomic? false   # the injected change is non-atomic
    end
  end
end
```

### What you get

- `:by_own_author` evaluates in memory — the lazy change sees the actor
  does not need `^arg(:center_id)` and skips the DB load entirely.
- `:at_own_unit` evaluates in memory against a resource-computed value —
  the caller cannot tamper with `:center_id` because the resource reads
  it off its own FK.
- Composite scopes work cleanly:

  ```elixir
  scope :at_own_unit_and_small, [:at_own_unit], expr(total_amount <= 100)
  ```

- Multi-hop is the same declaration shape:

  ```elixir
  resolve_argument :organization_id,
    from_path: [:order, :customer, :organization_id]
  ```

### Caller requirements

- **Always pass `actor:`** to `for_update/4`, `for_create/4`,
  `for_destroy/4`. The change needs the actor to introspect permissions.
- **Set `require_atomic? false`** on affected update/destroy actions if
  your data layer defaults to atomic updates.

## Recipe 2: Parent-shared children with `scope_through`

**Problem.** Users hold per-workspace instance permissions
(`"workspace:ws_abc123:read:"`). Posts live under workspaces via
`belongs_to :workspace`. We want that single workspace grant to cover
every post in the workspace — without copying the grant onto each post.

**Solution.** Declare `scope_through :workspace` on the child. AshGrant
propagates the parent's instance permissions through the FK automatically
for reads, writes, and `CanPerform` calculations.

```elixir
defmodule MyApp.Workspaces.Post do
  use Ash.Resource,
    domain: MyApp.Workspaces,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    default_policies true

    scope :always, true
    scope :own, expr(author_id == ^actor(:id))

    # Propagate Workspace instance permissions through :workspace FK
    scope_through :workspace
  end

  relationships do
    belongs_to :workspace, MyApp.Workspaces.Workspace, allow_nil?: false
  end
end
```

With permissions `["workspace:ws_abc:read:", "post:*:read:own"]`:

- **Reads** — filter becomes
  `(author_id == ^actor(:id)) OR (workspace_id IN ["ws_abc"])`.
- **Writes** — `check/1` succeeds when either the RBAC scope matches or
  the parent instance is in the actor's set.
- **`can_read?` calculation** — same OR filter, compiled to SQL.

### Narrowing to specific actions

```elixir
scope_through :workspace, actions: [:read, :update]
```

Only `:read` and `:update` propagate; `:destroy` falls back to RBAC only.

### When the parent uses a custom `instance_key`

If the parent resource declares `instance_key :external_id` and the
child's FK doesn't match the parent's destination attribute, AshGrant
emits an `exists()` subquery through the relationship automatically —
the child declaration doesn't change.

## Recipe 3: Combining `scope_through` with RBAC scopes

A user may hold both:

```
["workspace:ws_abc:read:", "post:*:read:own"]
```

No extra wiring needed. Recipe 2's declaration already produces:

```
(workspace_id IN ["ws_abc"]) OR (author_id == ^actor(:id))
```

Parent-instance filters and RBAC scope filters combine with **OR** — an
actor sees posts reachable via *any* of their grants.

### Adding a conditional layer

Want the parent grant to allow reads only while the post is `status ==
:open`? Do not put that condition on `scope_through` — it's boolean
propagation, not a filter. Instead:

1. Keep `scope_through :workspace` for unconditional reach, **or**
2. Drop `scope_through` and model the parent-share with an RBAC scope
   that joins back through the relationship:

   ```elixir
   scope :in_shared_workspace_and_open,
     expr(status == :open and
          exists(workspace.shares, user_id == ^actor(:id)))
   ```

   Permission: `"post:*:read:in_shared_workspace_and_open"`.

Option 2 keeps everything at the RBAC-scope layer — one concept, one
combination rule (multiple permissions = OR). Option 1 is simpler when
the share is genuinely unconditional.

## Recipe 4: `resolve_argument` + `scope_through` together

**Problem.** A `Comment` belongs to a `Post`. The post in turn belongs
to a `Workspace`. We want two kinds of access:

1. Workspace-level sharing — a user holding
   `"workspace:ws_abc:read:"` can read every comment under every post in
   that workspace.
2. Content-level authorization on writes — a user can delete a comment
   only when the *post's* author is the current user
   (`comment → post.author_id`).

**Solution.** `scope_through` handles (1); `resolve_argument` handles
(2).

```elixir
defmodule MyApp.Workspaces.Comment do
  use Ash.Resource,
    domain: MyApp.Workspaces,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    default_policies true

    scope :always, true
    scope :own, expr(author_id == ^actor(:id))

    # Writing requires the post's author to match
    scope :on_own_post, expr(^arg(:post_author_id) == ^actor(:id))

    # Multi-hop: comment → post.author_id
    resolve_argument :post_author_id, from_path: [:post, :author_id]

    # Parent-share: any workspace share covers every comment under it
    scope_through :post, actions: [:read]
  end

  relationships do
    belongs_to :post, MyApp.Workspaces.Post, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy]

    update :update do
      accept [:body]
      require_atomic? false
    end
  end
end
```

With permissions
`["workspace:ws_abc:read:", "comment:*:destroy:on_own_post"]`:

- Read: combined `OR` filter covers workspace-shared posts' comments
  plus the actor's own (if they had an `:own` grant).
- Destroy: `check/1` evaluates `^arg(:post_author_id) == ^actor(:id)`;
  the injected change loads `:post` only when the actor holds a
  destroy-scope that needs `^arg(:post_author_id)`.

## Troubleshooting

### "Argument ... is not set" on write

The lazy change short-circuits when the actor is `nil` or holds no
scope referencing the argument. Check:

1. Did you pass `actor:` to `for_update/4` / `for_create/4`?
2. Does at least one of the actor's permissions for this action use a
   scope that references `^arg(<name>)`?

### Atomic update errors

`resolve_argument` injects a non-atomic change. Set
`require_atomic? false` on the affected update/destroy actions.

### `scope_through` has no effect

Common causes:

- The relationship is not `belongs_to`. `scope_through` only works
  through `belongs_to` (child points at parent).
- The `actions:` filter excludes the action you're testing.
- The actor has no parent instance permissions. `scope_through` only
  propagates **instance** permissions (`"workspace:ws_abc:read:"`),
  not RBAC permissions (`"workspace:*:read:always"`).

### Post-change FK on update

If your update changes the FK, `resolve_argument` reads the **original**
FK from `changeset.data`. That's usually what you want (authorize based
on the *current* state before the change), but if you need post-change
semantics you must resolve manually (see the
[hand-rolled version](argument-based-scope.md#hand-rolled-version-under-the-hood))
and read from `changeset.attributes` instead.

This applies only to scopes that read a `resolve_argument` argument. A scope
that reads the FK attribute itself, and a `scope_through` parent, is checked
against both the original and the written FK.

## See also

- [Argument-Based Scope](argument-based-scope.md) — deep dive on
  `resolve_argument`, multi-hop paths, tamper resistance.
- [Permissions](permissions.md#scope-through-parent-child-propagation)
  — `scope_through` reference.
- [Scopes](scopes.md) — scope inheritance and combination rules.
- [Migration Guide](migration.md) — moving off deprecated `write:` and
  `scope_resolver`.

# Argument-Based Scope Pattern

For authorization that depends on a value reachable only through a relationship
— e.g., "a user can refund an order only if the order belongs to one of their
units" — the natural first reach is a **relational scope** that traverses the
relationship directly:

```elixir
scope :at_own_unit, expr(order.center_id in ^actor(:own_org_unit_ids))
```

This works for read actions (Ash lowers it to SQL). For **write actions** it
forces AshGrant's DB-query fallback path, which has rough edges: composite
inheritance corner cases, limits on function-wrapped relational refs, and
pre/post-state ambiguity on updates that change foreign keys.

This guide describes an alternative that keeps scope expressions
**in-memory-evaluable** and moves the relationship traversal into the resource's
own change pipeline — with lazy loading so unrelated scopes pay no cost.

> **Prerequisite:** Familiarity with [Scopes](scopes.md) and
> [Authorization Patterns](authorization-patterns.md).

## The pattern in one sentence

**Declare scopes against action arguments, and let the resource populate those
arguments from its own relationships — only when the actor's permissions
actually need them.**

## Why argument-based instead of relational?

| Property | Relational `order.center_id in ...` | Argument-based `^arg(:center_id) in ...` |
|---|---|---|
| Expression evaluator | DB-query fallback on writes | In-memory, always |
| Composite inheritance | Fragile (see #83, #86) | Not involved |
| Pre/post state on update | Ambiguous if FK changes | Caller/resource decides explicitly |
| Multi-hop relationships | One SQL query per hop pattern | Resource loads what it needs, when it needs |
| Cost for scopes that don't need the relationship | Always pays | **Zero — load is skipped** |
| Tamper resistance | N/A | Guaranteed: resource resolves its own FKs |

The last two rows are where this pattern distinguishes itself. A scope like
`:by_own_author` (direct attribute) doesn't need to know about `order` at all.
The pattern lets you add relational scopes alongside it **without** forcing
every write to preload `order`.

## Using the DSL sugar (recommended)

AshGrant provides a `resolve_argument` entity that wires up the argument and
the lazy `change` automatically:

```elixir
defmodule MyApp.Orders.Refund do
  use Ash.Resource,
    domain: MyApp.Orders,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    resource_name "refund"

    scope :always, true
    scope :by_own_author, expr(author_id == ^actor(:id))

    # Argument-based: compares an action argument, not a relationship
    scope :at_own_unit,
      expr(^arg(:center_id) in ^actor(:own_org_unit_ids))

    scope :at_own_unit_and_small,
      [:at_own_unit],
      expr(total_amount <= 100)

    # Auto-generates :center_id argument + lazy change on every write action
    resolve_argument :center_id, from_path: [:order, :center_id]
  end

  attributes do
    uuid_primary_key :id
    attribute :author_id, :uuid, public?: true, allow_nil?: false
    attribute :total_amount, :integer, public?: true, allow_nil?: false
  end

  relationships do
    belongs_to :order, MyApp.Orders.Order, allow_nil?: false
  end

  policies do
    policy action_type(:read),                       do: authorize_if AshGrant.filter_check()
    policy action_type([:create, :update, :destroy]), do: authorize_if AshGrant.check()
  end

  actions do
    defaults [:read, :destroy]
    create :create, do: accept [:author_id, :total_amount, :order_id]

    update :update do
      accept [:total_amount]
      require_atomic? false
    end
  end
end
```

Notice what the scope **doesn't** say:

- No `exists(order.memberships, ...)`
- No dot-path `order.center_id`
- Just a plain comparison between an argument and an actor attribute

### What the transformer generates

`AshGrant.Transformers.AddArgumentResolvers` walks every scope at compile time
and records which arguments each scope references. For each `resolve_argument`
declaration, it then:

1. Validates the path: intermediates must be `belongs_to` relationships, the
   leaf must be an attribute. Invalid paths fail the compile.
2. Validates that at least one scope references `^arg(:center_id)` — a
   declaration no scope uses is a compile error.
3. Adds an `argument :center_id, <inferred_type>, allow_nil?: true` to every
   targeted write action (create, update, destroy).
4. Installs `AshGrant.Changes.ResolveArgument` on every targeted write action,
   with the compile-time list of "scopes that need this argument" baked in.

### Multi-hop paths

```elixir
resolve_argument :organization_id,
  from_path: [:order, :customer, :organization_id]
```

Works the same way — intermediates are belongs_to, leaf is an attribute.

### Restricting to specific actions

```elixir
resolve_argument :center_id,
  from_path: [:order, :center_id],
  for_actions: [:update, :destroy]
```

Defaults to all write actions; use `for_actions:` to narrow.

### Runtime behavior

For each write action's execution:

1. The change runs. If the actor is `nil` or none of the actor's permissions
   are for a scope that references this argument → **no-op**, argument stays
   unset.
2. Otherwise:
   - **create**: the change reads the first-hop foreign key from the
     changeset's attributes (e.g., `:order_id`), loads the head record, then
     walks any remaining path keys through loaded relationships.
   - **update / destroy**: the change loads the relationship path on
     `changeset.data` and reads the leaf attribute.
3. `Changeset.set_argument(:center_id, value)` is set; authorization proceeds.

#### Actor holds only `"refund:*:update:by_own_author"`

`:by_own_author` does not reference `^arg(:center_id)`. The change skips the
DB load and returns the changeset unchanged. Authorization evaluates
`author_id == ^actor(:id)` in-memory. Zero overhead.

#### Actor holds only `"refund:*:update:at_own_unit"`

`:at_own_unit` references `^arg(:center_id)`, which is in the
`scopes_needing` set baked in at compile time. The change loads `:order`,
sets the argument, and authorization evaluates
`^arg(:center_id) in ^actor(:own_org_unit_ids)`.

## Why this is safe

A common worry about argument-based checks is: **"what if the caller tampers
with the argument?"** — e.g., passing a `center_id` they have access to while
actually updating a record from a different center.

This pattern avoids that entirely: **the resource itself computes the argument
from its own authoritative FK relationships.** The caller doesn't supply
`:center_id`; the change does. The only way an attacker could influence the
argument is to influence the actual `order_id` — which would change what
record is updated in the first place.

## When to use this pattern

Prefer argument-based scope + `resolve_argument` when:

- The authorization check reads through one or more relationships
  (`refund.order.center_id`, `comment.post.author_id`, etc.).
- You have multiple scopes on the same action, some needing the relationship
  and some not, and you don't want to pay the load cost for the cheap scopes.
- The composite inheritance, function wrapping, or pre/post-state concerns of
  the relational scope path bite you.

Prefer relational scopes (`expr(order.center_id in ...)`) when:

- The scope is used only on read actions (Ash lowers to SQL cleanly).
- The scope is on a single-attribute, same-resource comparison — there's
  nothing to resolve.

## Gotchas

### `for_update`/`for_create`/`for_destroy` must receive the actor

The change runs during `for_<action>/4`. It needs the actor to introspect
permissions. If your caller builds the changeset without the actor and only
passes it to `Ash.update/2`, the change sees `nil` and skips the load — and
the authorization fails with nil arguments.

**Always pass `actor:` to `for_*/4` when using this pattern.**

### `require_atomic? false` on update/destroy

The generated change does not implement the atomic protocol. If your data
layer supports atomic updates (most do), set `require_atomic? false` on
affected actions.

### Relationship with the `write:` scope option

The `write:` option on `scope` was an earlier escape hatch for the same
problem this pattern solves: a simpler, in-memory-evaluable expression for
write actions when the main filter traverses relationships.

With argument-based scopes + `resolve_argument`, the scope expression is
already in-memory-evaluable and the relationship traversal lives in the
change module. **`write:` is deprecated as of 0.14** — new code should use
this pattern. Existing `write:` usage still compiles (with a deprecation
warning) to give projects time to migrate.

## Hand-rolled version (under the hood)

The DSL sugar is equivalent to the following hand-rolled wiring. Useful to
know when you need a customized variant (e.g., different resolution logic for
specific actions):

```elixir
# Resource — no resolve_argument entity
ash_grant do
  scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
end

actions do
  update :update do
    accept [:total_amount]
    require_atomic? false
    argument :center_id, :uuid, allow_nil?: true
    change {MyApp.Orders.ResolveCenterIdFromOrder, []}
  end
end
```

```elixir
defmodule MyApp.Orders.ResolveCenterIdFromOrder do
  use Ash.Resource.Change
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, ctx) do
    actor = ctx.actor || changeset.context[:private][:actor]

    if needs_center_id?(changeset.resource, actor) do
      loaded = Ash.load!(changeset.data, :order, authorize?: false)
      Changeset.set_argument(changeset, :center_id, loaded.order.center_id)
    else
      changeset
    end
  end

  defp needs_center_id?(_resource, nil), do: false

  defp needs_center_id?(resource, %{permissions: perms}) when is_list(perms) do
    Enum.any?(perms, &scope_references_center_id?(resource, &1))
  end

  defp needs_center_id?(_, _), do: false

  defp scope_references_center_id?(resource, perm_string) do
    with {:ok, parsed} <- AshGrant.Permission.parse(perm_string),
         scope_atom when is_atom(scope_atom) <- safe_to_atom(parsed.scope),
         filter when filter not in [nil, true, false] <-
           AshGrant.Info.resolve_write_scope_filter(resource, scope_atom, %{}) do
      AshGrant.ArgumentAnalyzer.references_arg?(filter, :center_id)
    else
      _ -> false
    end
  end

  defp safe_to_atom(s) when is_atom(s), do: s

  defp safe_to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end
end
```

Prefer the DSL sugar unless you need this kind of surgical control.

## Reference implementation

See the test suite for working implementations of both styles:

- `test/support/resources/auth_pattern_refund_dsl.ex` — DSL sugar
- `test/support/resources/auth_pattern_refund.ex` — hand-rolled change module
- `test/ash_grant/resolve_argument_dsl_test.exs` — DSL behavior tests
- `test/ash_grant/argument_based_scope_test.exs` — hand-rolled behavior tests
- `test/ash_grant/argument_analyzer_test.exs` — unit tests for the AST walker
- `test/ash_grant/resolve_argument_validation_test.exs` — compile-time errors
- `test/ash_grant/resolve_argument_property_test.exs` — property-based tests

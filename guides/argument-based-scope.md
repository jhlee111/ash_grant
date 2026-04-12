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

| Property | Relational scope `order.center_id in ...` | Argument-based scope `^arg(:center_id) in ...` |
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

## Full example: Refund → Order → center_id

### The resources

```elixir
defmodule MyApp.Orders.Order do
  use Ash.Resource, domain: MyApp.Orders, data_layer: AshPostgres.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :center_id, :uuid, public?: true, allow_nil?: false
  end
end

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
    scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
  end

  attributes do
    uuid_primary_key :id
    attribute :author_id, :uuid, public?: true, allow_nil?: false
    attribute :amount,   :integer, public?: true, allow_nil?: false
  end

  relationships do
    belongs_to :order, MyApp.Orders.Order do
      allow_nil? false
    end
  end

  policies do
    policy action_type(:read),                       do: authorize_if AshGrant.filter_check()
    policy action_type([:create, :update, :destroy]), do: authorize_if AshGrant.check()
  end

  actions do
    defaults [:read, :destroy]
    create :create, do: accept [:author_id, :amount, :order_id]

    update :update do
      accept [:amount]
      require_atomic? false
      argument :center_id, :uuid, allow_nil?: true
      change {MyApp.Orders.ResolveCenterIdFromOrder, []}
    end
  end
end
```

Notice what the scope **doesn't** say:

- No `exists(order.memberships, ...)`
- No dot-path `order.center_id`
- Just a plain comparison between an argument and an actor attribute

### The argument resolver

```elixir
defmodule MyApp.Orders.ResolveCenterIdFromOrder do
  use Ash.Resource.Change
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, change_ctx) do
    actor = change_ctx.actor || changeset.context[:private][:actor]

    if needs_center_id?(changeset.resource, actor) do
      loaded = Ash.load!(changeset.data, :order, authorize?: false)
      Changeset.set_argument(changeset, :center_id, loaded.order.center_id)
    else
      changeset
    end
  end

  defp needs_center_id?(_resource, nil), do: false

  defp needs_center_id?(resource, actor) do
    actor
    |> permissions_for()
    |> Enum.any?(&scope_references_arg?(resource, &1, :center_id))
  end

  defp permissions_for(%{permissions: perms}), do: perms
  defp permissions_for(_), do: []

  # Walks the scope's resolved filter expression looking for `^arg(name)`.
  defp scope_references_arg?(resource, perm_string, arg_name) do
    with {:ok, parsed} <- AshGrant.Permission.parse(perm_string),
         scope_atom when is_atom(scope_atom) <- safe_to_atom(parsed.scope),
         filter when filter not in [nil, true, false] <-
           AshGrant.Info.resolve_write_scope_filter(resource, scope_atom, %{}) do
      references_template?(filter, {:_arg, arg_name})
    else
      _ -> false
    end
  end

  defp safe_to_atom(s) when is_atom(s), do: s
  defp safe_to_atom(s) when is_binary(s),
    do: (try do: String.to_existing_atom(s), rescue: (ArgumentError -> nil))

  defp references_template?(template, template), do: true
  defp references_template?(%Ash.Query.Call{args: args}, template),
    do: Enum.any?(args, &references_template?(&1, template))
  defp references_template?(%Ash.Query.BooleanExpression{left: l, right: r}, t),
    do: references_template?(l, t) or references_template?(r, t)
  defp references_template?(%Ash.Query.Not{expression: e}, t),
    do: references_template?(e, t)
  defp references_template?(%{__function__?: true, arguments: args}, t),
    do: Enum.any?(args, &references_template?(&1, t))
  defp references_template?(%{__struct__: _, left: l, right: r}, t),
    do: references_template?(l, t) or references_template?(r, t)
  defp references_template?(list, t) when is_list(list),
    do: Enum.any?(list, &references_template?(&1, t))
  defp references_template?(_, _), do: false
end
```

### What happens at runtime

#### Actor holds only `"refund:*:update:by_own_author"`

1. Caller invokes `Refund.update(refund, %{amount: 200})` with the actor.
2. `for_update/4` runs the `change`. `needs_center_id?/2` walks the actor's
   permissions and asks: "does any scope in play reference `^arg(:center_id)`?"
   The only in-play scope is `:by_own_author`, which compares `author_id`
   directly. Answer: **no**.
3. The change **skips `Ash.load!`** and returns the changeset unchanged.
4. Authorization evaluates `author_id == ^actor(:id)` in-memory. No DB load.

#### Actor holds only `"refund:*:update:at_own_unit"`

1. `for_update/4` runs the `change`. `needs_center_id?/2` finds that
   `:at_own_unit` references `^arg(:center_id)`. Answer: **yes**.
2. The change calls `Ash.load!(refund, :order)` and `Changeset.set_argument(:center_id, loaded.order.center_id)`.
3. Authorization evaluates `^arg(:center_id) in ^actor(:own_org_unit_ids)` —
   filled in as `<loaded-center-id> in <actor-unit-list>`. Plain boolean.

#### Actor holds both

The change runs one load (deduped by Ash). Both scopes evaluate correctly:
`by_own_author` from direct attributes, `at_own_unit` from the injected argument.

## Why this is safe

A common worry about argument-based checks is: **"what if the caller tampers
with the argument?"** — e.g., passing a `center_id` they have access to while
actually updating a record from a different center.

This pattern avoids that entirely: **the resource itself computes the argument
from its own authoritative FK relationships.** The caller doesn't supply
`:center_id`; the resource's `change` does. The only way an attacker could
influence the argument is to influence the actual `order_id` — which would
change what record is updated in the first place.

If you ever need to accept a caller-supplied argument as an optimization (e.g.,
it's already in hand from a prior query), validate it against the resource's
own resolution before trusting it.

## When to use this pattern

Prefer argument-based scope + resource-local argument resolution when:

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

The `change` runs during `for_<action>/4`. It needs the actor to introspect
permissions. If your caller builds the changeset without the actor and only
passes it to `Ash.update/2`, the change sees `nil` and skips the load — and
the authorization fails with nil arguments.

**Always pass `actor:` to `for_*/4` when using this pattern.** Ash's
conventions recommend this anyway.

### `require_atomic? false` on update/destroy

Functions-as-changes don't implement the atomic protocol by default. If your
resource's data layer supports atomic updates (most do), set
`require_atomic? false` on the action, or provide an `atomic/3` callback on
the change.

### The change should be idempotent

The introspection walks the scope expressions each call. If you have many
scopes and many writes, and the walk shows up in profiles, cache the
per-resource "scope → uses arg X?" map. The logic is pure and compile-time
computable from the DSL.

## Relation to `default_policies`

`default_policies true` auto-generates a blanket `AshGrant.check()` policy for
write actions. This pattern is fully compatible: declare the argument and
change on the action, and `default_policies` does the rest.

If you want argument resolution to happen without explicitly wiring a change on
every action, encapsulate the change + argument declaration in a small macro
or a global action template.

## Reference implementation

See the test suite for a working implementation:

- `test/support/resources/auth_pattern_order.ex`
- `test/support/resources/auth_pattern_refund.ex`
- `test/support/auth_pattern/resolve_center_id_from_order.ex`
- `test/ash_grant/argument_based_scope_test.exs`

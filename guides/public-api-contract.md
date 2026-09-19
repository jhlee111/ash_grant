# Public API Contract

This guide describes the **stable API surface** that external consumers can
build on. It exists because AshGrant is increasingly consumed by
independent packages — `ash_grant_phoenix` (admin dashboard / LiveView),
`ash_grant_ai` (Ash AI tool surface), and custom IEx helpers — which all
need to share one core without being surprised by internal refactors.

If a module, function, struct field, or behaviour callback is documented
**in this file**, you may depend on it from outside the `:ash_grant` app
without pinning exact patch versions. Anything not listed here is
internal and may change at any time.

## Stability tiers

| Tier | Meaning | Breaking change policy |
|---|---|---|
| **Stable** | Part of the public contract | Only in major version bumps, with CHANGELOG notice and ≥ 1 minor of deprecation when feasible |
| **Provisional** | In the public contract but recently added | May tighten in a minor release if a real-world consumer finds a rough edge. Every entry below is marked when provisional |
| **Internal** | Everything else | Any release |

All identifier-based introspection added in v0.15 starts as **Provisional**.

## What's public

### `AshGrant.Introspect` — runtime introspection

The primary entry point for external tools. All functions take explicit
resource modules or string keys — they never rely on global state beyond
the standard Ash application config.

Resource / domain discovery:

- `list_domains/0` → `[module()]`
- `list_resources/1` → `[module()]` (opts: `:domains`)
- `find_resource_by_key/1` → `{:ok, module()} | :error`

Actor-oriented queries (already-loaded actor):

- `actor_permissions/3` → `[permission_status()]`
- `allowed_actions/3` → `[atom()]` or `[map()]` with `detailed: true`
- `can?/4` → `{:allow, map()} | {:deny, map()}`
- `permissions_for/3` → `[String.t()]`
- `available_permissions/1` → `[available_permission()]`
- `summarize_actor/2` → `[resource_summary()]` *(Provisional)*

Identifier-oriented queries (loads the actor via the resolver's
optional `load_actor/1` callback — see the behaviour section below):

- `explain_by_identifier/1` *(Provisional)*
- `can_by_identifier/3` *(Provisional)*
- `actor_permissions_by_id/2` *(Provisional)*

All identifier-based functions return a structured
`{:error, :unknown_resource | :actor_loader_not_implemented | :actor_not_found}`
tuple on failure — they never raise for these predictable conditions.

### `AshGrant.explain/4` — rich authorization explanation

Top-level entrypoint that returns an `AshGrant.Explanation.t()`:

```elixir
AshGrant.explain(MyApp.Post, :read, actor, %{})
```

The return value's field set is part of the contract (see below).

### `AshGrant.Explanation` struct

Stable fields:

| Field | Type | Notes |
|---|---|---|
| `:resource` | `module()` | The Ash resource module |
| `:action` | `atom()` | Action name |
| `:actor` | `term()` | The actor passed in |
| `:decision` | `:allow \| :deny` | The final decision |
| `:reason` | atom | Low-level reason (internal-shaped) |
| `:reason_code` | `:allow_matched \| :deny_rule_matched \| :no_matching_permission \| nil` | Stable branching code |
| `:summary` | `String.t()` | Human/LLM-readable one-liner |
| `:matching_permissions` | `[map()]` | Permissions that contributed to the decision |
| `:evaluated_permissions` | `[map()]` | All evaluated permissions with per-permission reasons |
| `:deny_rule` | `map() \| nil` | The deny rule that won, if any |
| `:scope_filter` | `Ash.Expr.t() \| nil` | Raw scope filter expression |
| `:scope_filter_string` | `String.t() \| nil` | Human/LLM-readable stringification of `scope_filter` |

**`reason_code` and `summary` and `scope_filter_string` are Provisional** —
added in v0.15. Other fields are Stable.

`AshGrant.Explanation.to_string/1` is Stable — used for terminal output.

### `AshGrant.Permission` struct

Stable fields: `:deny`, `:resource`, `:instance_id`, `:action`, `:scope`,
`:field_group`, `:description`, `:source`, `:metadata`.

Stable functions:

- `parse!/1`, `parse/1`
- `to_string/1`
- `matches?/4`
- `deny?/1`
- `from_input/1`

### `AshGrant.PermissionInput` struct

Stable fields: `:string`, `:description`, `:source`, `:metadata`.

Stable functions: `new/2`, `to_string/1`.

This is the preferred shape for resolvers that want to attach
human-readable metadata (description, source) to each permission string.

### `AshGrant.PermissionResolver` behaviour

Required callback (Stable):

```elixir
@callback resolve(actor(), context()) :: [permission()]
```

Optional callback (Provisional, added in v0.15):

```elixir
@callback load_actor(id :: term()) :: {:ok, actor()} | :error
```

`load_actor/1` powers the identifier-based introspection entry points.
Implementing it opts a resolver module into CLI tools, admin dashboards,
and LLM agents that only have an actor ID — not a hydrated struct.

Not implementing `load_actor/1` is fine; identifier-based functions
return `{:error, :actor_loader_not_implemented}` in that case. Existing
resolvers (including anonymous-function resolvers) keep working
unchanged.

### `AshGrant.Permissionable` protocol

Stable. Lets custom structs flow through the resolver pipeline by
providing a `to_permission_input/1` conversion.

### `AshGrant.ExprStringify`

**Provisional.** Added in v0.15.

- `to_string/1` → `String.t()`

Converts an `Ash.Expr` term into a human/LLM-readable string, humanizing
internal reference tuples:

| Internal | Stringified |
|---|---|
| `{:_actor, :id}` | `^actor(:id)` |
| `{:_context, :key}` | `^context(:key)` |
| `:_tenant` | `^tenant()` |

Used internally to populate `Explanation.scope_filter_string`. You can
also call it directly when you have a standalone filter expression to
render.

**Contract**: always returns a binary; never raises for arbitrary terms
(falls back to `inspect`).

## JSON encoding

Every struct listed below encodes cleanly via `Jason.encode!/1` and the
result never leaks module atoms or raw `Ash.Expr` AST — this is a hard
contract, because `ash_grant_ai` returns these as LLM tool responses
and `ash_grant_phoenix` renders them as API responses.

| Struct | Encoding notes |
|---|---|
| `AshGrant.Permission` | Derived; all fields encoded as-is |
| `AshGrant.PermissionInput` | Derived; all fields encoded as-is |
| `AshGrant.Explanation` | Custom impl: `resource` rendered via `inspect`, `actor` rendered via `inspect`, `scope_filter` **omitted** (use `scope_filter_string` instead), field group `mask_with` functions stripped |

If you find a value that breaks round-tripping through JSON, treat it as
a bug — open an issue.

## Mix task: `mix ash_grant.explain`

Stable CLI wrapper around `Introspect.explain_by_identifier/1`:

```
mix ash_grant.explain --actor USER_ID --resource RESOURCE_KEY --action ACTION \
  [--format text|json] [--context '<json>']
```

Exit codes are part of the contract:

| Code | Meaning |
|---|---|
| `0` | Explanation produced (allow or deny both succeed) |
| `1` | Lookup failure (`unknown_resource`, `actor_not_found`, `actor_loader_not_implemented`) |
| `2` | Usage error (missing option, bad `--context`, unknown `--format`) |

JSON output is the `Jason.encode!/1` representation of the
`Explanation.t()` — see the JSON encoding section.

## Static permission-string checking (Provisional)

Added for [#162](https://github.com/jhlee111/ash_grant/issues/162). Everything in
this section is **Provisional**.

- `AshGrant.PermissionValidation.check/2`, `check_all/2` and `errors?/1`. The
  `issue` map's keys (`:code`, `:severity`, `:segment`, `:message`, `:permission`,
  `:resources`) and the issue codes listed in the module's documentation are part
  of the contract; `:message` text is for humans and may change in any release.
  The request-time `validate/3` in the same module stays internal.
- `AshGrant.Validations.PermissionStrings` and its options (`:attribute`,
  `:otp_app`, `:resources`, `:reject`). Each error is an
  `Ash.Error.Changes.InvalidAttribute` whose `:value` is the offending string and
  whose `vars[:codes]` lists the issue codes.
- `mix ash_grant.check_permissions FILE [--otp-app APP] [--format text|json]`.
  Exit codes are part of the contract:

  | Code | Meaning |
  |---|---|
  | `0` | No issue of severity `:error` (warnings are printed and do not fail) |
  | `1` | At least one `:error` |
  | `2` | Usage error (missing or unreadable file, bad option, no resources to check against) |

  With `--format json`, the top-level keys (`checked`, `errors`, `warnings`,
  `results`) and each result's `label`, `permission` and `issues` are part of the
  contract.

`AshGrant.PermissionValidation.ResourceIndex` is internal.

## What's _not_ public

These modules exist in `lib/` but are **internal** — do not call them
from outside the `:ash_grant` app:

- `AshGrant.Evaluator` — permission matching / scope resolution internals
- `AshGrant.Explainer` — construction of `Explanation` structs
- `AshGrant.Check`, `AshGrant.FilterCheck`, `AshGrant.Calculation.*` — Ash integration
- `AshGrant.Transformers.*`, `AshGrant.ArgumentAnalyzer`, `AshGrant.Changes.*` — compile/runtime machinery
- `AshGrant.Info` — Spark-generated introspection; prefer `AshGrant.Introspect`
- Everything under `AshGrant.Dsl`, `AshGrant.Domain.Dsl` — DSL internals
- Everything under `Mix.Tasks.*` other than `ash_grant.explain` and `ash_grant.check_permissions`

If you need something here to be public, open an issue describing the
consumer and we'll promote it.

## Versioning

AshGrant follows Semantic Versioning with respect to this contract only:

- **Patch** (`0.x.Y`) — bug fixes, internal refactors, additions marked Provisional
- **Minor** (`0.X.y`) — additions to the public contract
- **Major** (`X.y.z`) — breaking changes to the public contract

Provisional entries may tighten or rename inside a minor release; each
change will ship in CHANGELOG under a **Breaking (Provisional)** heading.
Once an entry leaves Provisional it follows the full Stable policy.

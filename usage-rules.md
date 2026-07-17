# AshGrant Usage Rules

> These rules help LLMs correctly use AshGrant — a permission-based authorization
> extension for Ash Framework. Follow them when generating code that uses AshGrant.

## What AshGrant Is

AshGrant is a **permission evaluation** extension, not a role management system.
It evaluates permission strings against resources and actions using deny-wins semantics.
It integrates with Ash's policy authorizer via three check types.

Roles, role assignments, and permission storage are **your responsibility**.
AshGrant only needs a resolver that returns permission strings for a given actor.

## Permission String Format

```
[!]resource:instance_id:action:scope[:field_group]
```

| Part          | Required | Description                                      |
|---------------|----------|--------------------------------------------------|
| `!`           | No       | Deny prefix — deny rules always override allows  |
| `resource`    | Yes      | Resource name or `*` for all                     |
| `instance_id` | Yes      | `*` for RBAC, specific ID for instance access    |
| `action`      | Yes      | Action name, `*` for all, or `@read` type wildcard |
| `scope`       | Yes      | Scope name (e.g., `all`, `own`) or empty string  |
| `field_group` | No       | 5th part for column-level access control         |

### RBAC permissions (instance_id = `*`)

```elixir
"blog:*:read:always"           # Read all blogs
"blog:*:read:published"     # Read only published blogs
"blog:*:update:own"         # Update own blogs only
"blog:*:*:always"              # All actions on all blogs
"*:*:read:always"              # Read all resources
"blog:*:@read:always"          # All :read-TYPE actions (list, search, by_slug) — by type, never by name
"!blog:*:delete:always"        # DENY delete on all blogs
```

### Instance permissions (specific instance_id)

```elixir
"blog:post_abc123:read:"        # Read specific post (no scope condition)
"blog:post_abc123:*:"           # Full access to specific post
"!blog:post_abc123:delete:"     # DENY delete on specific post
"doc:doc_123:update:draft"      # Update only when document is in draft (ABAC)
```

Instance permissions with an empty scope (trailing colon) mean unconditional access.
Instance permissions with a scope name impose an attribute-based condition.

### DON'T: Use `read*` — it is a type wildcard, not a prefix glob

`@read` matches any action whose **Ash action type** is `:read`, regardless of its
name. The older `read*` spelling means exactly the same thing, but reads like a
prefix glob and never was one — it does **not** match `read_all` by name, and it
does match `:read`-type actions with unrelated names like `list_published`.

```elixir
# DON'T — deprecated spelling; looks like a name glob, isn't one. Removed in v1.0.0.
"blog:*:read*:always"

# DO — explicit: matches every :read-TYPE action (list, search, by_slug)
"blog:*:@read:always"

# DO — exact action NAME match, regardless of that action's type
"blog:*:read:always"
```

Valid types are Ash's own: `@action`, `@read`, `@create`, `@update`, `@destroy`.
Anything else silently never matches — deletion is `@destroy`, **not** `@delete`.

### DON'T: Put a type wildcard on an instance permission

Instance matching has no action type available, so a type wildcard on an instance
permission never matches anything. The grant is dead and fails silently.

```elixir
# DON'T — matches nothing, ever
"blog:post_abc123:@read:"

# DO — exact action name, or the catch-all wildcard
"blog:post_abc123:read:"
"blog:post_abc123:*:"
```

Because permission strings live in your database rather than your source, there is
no compile-time warning for either rule above. Find offending grants with
`mix ash_grant.verify`, or audit your own store:

```elixir
MyApp.Role
|> MyApp.Repo.all()
|> Enum.flat_map(& &1.permissions)
|> Enum.flat_map(&AshGrant.Permission.diagnostics/1)
```

### DON'T: Check a type wildcard without supplying the action type

A type wildcard can only be evaluated against an Ash action **type**. If you call a
matcher that has no action type, the wildcard silently fails to match — and the answer
you get back may be **wrong**, not merely uninformed. This is the trap behind
"my grant is in the database but the feature is gone for the people it targets."

```elixir
# DON'T — no action_type, so "@read" cannot be evaluated. Returns false even though
# this actor should be allowed. The false is fabricated, indistinguishable from a deny.
Evaluator.has_access?(["blog:*:@read:always"], "blog", "read")        # => false (!)

# DO — pass the action type; now the type wildcard is evaluated.
Evaluator.has_access?(["blog:*:@read:always"], "blog", "read", :read) # => true

# DO — better, hand a resource MODULE to Introspect, which resolves the type for you.
AshGrant.Introspect.can?(MyApp.Blog.Post, :read, actor)               # => {:allow, ...}
```

The framework-generated checks (`AshGrant.Check`, `FilterCheck`) always pass the type,
so this only bites **direct** calls to `AshGrant.Evaluator` from your own code. When it
happens, `AshGrant.IndeterminateMatch` reports it (`Logger.warning` by default; set
`config :ash_grant, indeterminate_type_wildcard: :strict` to raise instead). It never
changes the returned value — it only tells you the value cannot be trusted.

> A defensive `"@read"` + literal `"read"` pair (or `"read*"` + `"read"`) does still
> work, because the literal matches regardless of type. But prefer fixing the call to
> pass the type: the pair silently breaks the moment someone removes the literal.

### Field-level permissions (5-part format)

```elixir
"employee:*:read:always:public"       # See only public fields
"employee:*:read:always:sensitive"    # See public + sensitive fields
"employee:*:read:always:confidential" # See all fields including confidential
```

When the 5th part is omitted (4-part format), all fields are visible.

### DON'T: Combine a deny (`!`) with a field_group

Field-group access is **positive-only**. A deny rule must not carry a field_group
(5th part) — express column restrictions in the resource's `field_group`
definition (`inherits`/`except`/`mask`) and grant groups positively instead.

```elixir
# DON'T — a deny carrying a field_group is invalid; it over-denies the whole action
"!employee:*:read:always:sensitive"

# DO — grant the group that contains exactly the fields the actor may see
"employee:*:read:always:public"     # everything except sensitive/confidential
```

The `field_group_permissions` option on the `ash_grant` block controls how an
invalid field-group deny is signaled (it never changes the outcome, which is
already fail-closed): `:off` (silent), `:warn` (logs a warning — default), or
`:strict` (raises `AshGrant.PermissionValidation.InvalidPermissionError`). Set a
global default with `config :ash_grant, field_group_permissions: :strict`.
Field-group visibility is **per-record**: with `default_field_policies: true`, a
non-trivial scope or a specific instance id on a 5-part grant restricts the
group's fields to the matching rows only (forbidden elsewhere). Combine a broad
row grant with a narrow field grant to vary field visibility by record:

```elixir
# public fields on all rows, sensitive fields only on owned rows
["employee:*:read:always:public", "employee:*:read:own:sensitive"]
```

A trivial scope (`always`) keeps the group visible on every row (action-wide).

## Resource Setup

### Always include these three things

1. `authorizers: [Ash.Policy.Authorizer]` in resource options
2. `extensions: [AshGrant]` in resource options
3. An `ash_grant` block with at least a `resolver` and one scope

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver MyApp.PermissionResolver
    scope :always, true
    scope :own, expr(author_id == ^actor(:id))
  end
end
```

### DO: Use `default_policies: true` to eliminate boilerplate

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true  # Generates read + write policies automatically

  scope :always, true
  scope :own, expr(author_id == ^actor(:id))
end
# No policies block needed!
```

### DO: Use explicit policies when you need bypasses or custom logic

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope :always, true
  scope :own, expr(author_id == ^actor(:id))
end

policies do
  bypass actor_attribute_equals(:role, :admin) do
    authorize_if always()
  end

  policy action_type(:read) do
    authorize_if AshGrant.filter_check()
  end

  policy action_type([:create, :update, :destroy]) do
    authorize_if AshGrant.check()
  end
end
```

### DON'T: Use both `default_policies: true` and a manual `policies` block

The transformer adds policies automatically. Defining both creates conflicts.

### DON'T: Forget `authorizers: [Ash.Policy.Authorizer]`

AshGrant generates policy checks, but Ash must be told to enforce them.

## DSL Configuration

### `ash_grant` block options

| Option                 | Type              | Required | Default | Description                                                  |
|------------------------|-------------------|----------|---------|--------------------------------------------------------------|
| `resolver`             | module or fun/2   | Yes      | —       | Resolves permissions for actors                              |
| `default_policies`     | bool/atom         | No       | `false` | `true`, `:always`, `:read`, or `:write`                        |
| `default_field_policies`| boolean          | No       | `false` | Auto-generate `field_policies` from `field_group` definitions|
| `resource_name`        | string            | No       | derived | Override resource name for permission matching               |
| `instance_key`         | atom              | No       | `:id`   | Field to match instance permission IDs against               |

`resource_name` defaults to the last segment of the module name, lowercased
(e.g., `MyApp.Blog.Post` becomes `"post"`).

`instance_key` changes which field instance IDs are matched against. By default,
`"feed:feed_abc:read:"` generates `WHERE id IN ('feed_abc')`. With
`instance_key :feed_id`, it generates `WHERE feed_id IN ('feed_abc')`.

### `scope_through` entity

Propagates a parent resource's instance permissions to a child resource via a
`belongs_to` relationship.

```elixir
scope_through :relationship_name
scope_through :relationship_name, actions: [:read, :update]
```

```elixir
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
```

When a user has `"feed:feed_abc:read:"`, they can read all posts where
`feed_id == "feed_abc"`. Use `actions:` to limit propagation to specific actions.

### Scope entity

```elixir
scope :name, filter_expression
scope :name, [:parent_scopes], filter_expression
scope :name, filter_expression, description: "Human-readable text"
```

- Use `true` for a scope that matches all records (no filtering).
- Use `expr(...)` for attribute-based filtering.
- Use the optional second argument (list of atoms) to inherit from parent scopes.
- `write:` option exists but is **deprecated** (see "DON'T: Use the `write:`
  scope option" below) — prefer `resolve_argument` for multi-hop cases.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :always, true
  scope :own, expr(author_id == ^actor(:id))
  scope :published, expr(status == :published)
  scope :own_draft, [:own], expr(status == :draft)  # own AND draft
  scope :same_tenant, expr(tenant_id == ^tenant())  # Multi-tenancy
end
```

### Read vs write scope evaluation

- **Reads** — scopes compile to SQL via `AshGrant.filter_check/1`.
- **Writes** — scopes are evaluated by `AshGrant.check/1`. Simple attribute
  scopes run in memory; single-hop relational scopes (`exists()`, dot-paths)
  fall back to a DB query automatically. For multi-hop or composite cases,
  use the `resolve_argument` entity (see next section).

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  # Simple — in-memory for writes
  scope :own, expr(author_id == ^actor(:id))

  # Single-hop relational — DB query fallback on writes
  scope :team_member, expr(exists(team.members, user_id == ^actor(:id)))
end
```

> **The `write:` scope option is deprecated as of 0.14.** See the "DON'T:
> Use the `write:` scope option" rule below.

### `resolve_argument` entity (argument-based scopes)

For authorization that reaches through one or more relationships, declare
scopes against an action argument and let the resource populate the argument
from its own relationships:

```elixir
ash_grant do
  scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))

  # The transformer auto-injects `argument :center_id` + a lazy change on
  # every create/update/destroy action. The change only loads :order when
  # an in-play permission uses a scope that references ^arg(:center_id).
  resolve_argument :center_id, from_path: [:order, :center_id]
end
```

Options:

| Option | Required | Description |
|--------|----------|-------------|
| `from_path` | Yes | List of atoms walking belongs_to relationships to a leaf attribute. Example: `[:order, :center_id]`. Multi-hop is supported: `[:order, :customer, :organization_id]`. |
| `for_actions` | No | Restrict injection to specific action names. Defaults to all create/update/destroy actions. |

Compile-time validation:
- Path intermediates must be `:belongs_to`; the leaf must be an attribute.
- At least one scope must reference `^arg(<name>)` (dead declarations error out).

See `guides/argument-based-scope.md` for the full rationale and examples.

### Field group entity

```elixir
field_group :name, [:field1, :field2]
field_group :name, [:field1, :field2], inherits: [:parent_groups]
```

Field groups define sets of fields for column-level read authorization.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  field_group :public, [:name, :department, :position]
  field_group :sensitive, [:phone, :address], inherits: [:public]          # Inherits public
  field_group :confidential, [:salary, :ssn], inherits: [:sensitive]      # Inherits sensitive
end
```

## Scope Patterns

### Actor references

Use `^actor(:field)` to reference the current actor's attributes:

```elixir
scope :own, expr(author_id == ^actor(:id))
scope :same_org, expr(org_id == ^actor(:org_id))
```

### Tenant references

Use `^tenant()` for multi-tenant scopes:

```elixir
scope :same_tenant, expr(tenant_id == ^tenant())
```

### Context injection

Use `^context(:key)` for injectable, testable values:

```elixir
# Definition
scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))
scope :threshold, expr(amount < ^context(:max_amount))

# Usage — inject at query time
Post
|> Ash.Query.for_read(:read)
|> Ash.Query.set_context(%{reference_date: Date.utc_today()})
|> Ash.read!(actor: actor)
```

### DO: Prefer `^context(:key)` over database functions for testability

```elixir
# DO
scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))

# DON'T
scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))
```

### Scope inheritance

Child scopes combine parent filters with AND logic:

```elixir
scope :own, expr(author_id == ^actor(:id))
scope :own_draft, [:own], expr(status == :draft)
# Effective filter: author_id == ^actor(:id) AND status == :draft
```

## Check Types

AshGrant provides three check types. Use the right one for each action type.

### `AshGrant.filter_check/1` — for read actions

Returns a filter expression that limits query results. Supports `exists()` scopes
because filters are converted to SQL.

```elixir
policy action_type(:read) do
  authorize_if AshGrant.filter_check()
end
```

### `AshGrant.check/1` — for write actions

Returns true/false by evaluating the scope in-memory against the record.

```elixir
policy action_type([:create, :update, :destroy]) do
  authorize_if AshGrant.check()
end
```

### `AshGrant.field_check/1` — for field-level access

Used inside Ash's `field_policies` block to control column visibility.

```elixir
field_policies do
  field_policy [:salary, :ssn] do
    authorize_if AshGrant.field_check(:confidential)
  end

  field_policy :* do
    authorize_if always()
  end
end
```

### DO: Override action names when Ash action names differ from permission actions

```elixir
policy action(:publish) do
  authorize_if AshGrant.check(action: "update")
end

policy action(:list_published) do
  authorize_if AshGrant.filter_check(action: "read")
end
```

### DON'T: Use `filter_check` for write actions or `check` for read actions

- `filter_check` returns filter expressions — meaningless for writes.
- `check` returns true/false — doesn't filter read results.

### DO: Use `exists()` scopes for simple single-hop writes — DB query fallback handles them

Scopes with `exists()` or dot-paths that traverse one belongs_to hop work
automatically for reads and writes. For writes, a DB query verifies the scope.

```elixir
# DO — works for both reads and writes automatically
scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))
```

### DO: Prefer argument-based scopes + `resolve_argument` for multi-hop or composite cases

When the authorization value lives one or more relationships away
(e.g., `refund → order → center_id`), or when you inherit a relational parent
into a composite child, prefer **argument-based scopes** over deep
relationship traversal in the scope expression itself:

```elixir
ash_grant do
  # Scope compares an action argument, not a traversed relationship
  scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
  scope :at_own_unit_and_small, [:at_own_unit], expr(total_amount <= 100)

  # Declare how the argument is populated from the record's relationships.
  # The transformer auto-injects an `argument :center_id` and a lazy change
  # on every create/update/destroy action. The change only loads :order
  # when an in-play permission uses a scope that references ^arg(:center_id).
  resolve_argument :center_id, from_path: [:order, :center_id]
end
```

Why this is better than `expr(order.center_id in ^actor(...))` on writes:

- Scope expression stays in-memory-evaluable — no DB query fallback.
- Composite inheritance works without edge cases.
- Scopes that don't reference the argument (e.g., `:by_own_author`) pay
  zero cost — the lazy change skips the DB load for those actors.
- The resource resolves its own FK, so callers can't tamper with the value.

Requirements:

- Always pass `actor:` to `for_update/4`, `for_create/4`, `for_destroy/4` —
  the lazy change needs the actor to introspect permissions.
- Set `require_atomic? false` on update/destroy actions if your data layer
  defaults to atomic updates.

See `guides/argument-based-scope.md` for the full pattern.

### DON'T: Use the `write:` scope option (deprecated)

The `write:` override has been **deprecated as of 0.14**. It was an escape
hatch for relational scopes that couldn't be evaluated in memory on writes;
argument-based scopes (above) subsume its use cases cleanly. Using `write:`
still compiles but emits a compile-time deprecation warning.

For new code:
- Multi-hop / composite: use `resolve_argument` + argument-based scopes.
- Read-only semantics: define a separate read-only scope name or gate at
  the policy layer, not via `write: false`.

## Deny-Wins Semantics

When both allow and deny rules match, **deny always wins**:

```elixir
permissions = [
  "blog:*:*:always",        # Allow all blog actions
  "!blog:*:delete:always"   # Deny delete
]

# Result: read ✓, update ✓, delete ✗ (deny wins)
```

Evaluation rules:
1. If **any** deny rule matches → **denied**
2. If no deny matches and at least one allow matches → **allowed**
3. If **no** rules match → **denied** (deny by default)

### DO: Rely on grants OR-composing — never on one grant shadowing another

When several allow permissions match the same resource and action (multiple
roles, add-on bundles), their scopes **OR-compose** on every path (read
filters, write checks, `can_perform`, policy tests): access is granted when
ANY grant's scope passes. Adding a narrower grant on top of a broader one
never subtracts access, and permission order never changes the outcome.

```elixir
permissions = [
  "schedule:*:cancel:online_content",  # narrow add-on bundle
  "schedule:*:*:always"                # blanket grant
]
# cancel on ANY schedule ✓ — the blanket grant passes; order is irrelevant
```

To restrict an action, use a `!` deny rule — a scoped allow grant can only
ever ADD access.

## PermissionResolver Behaviour

Implement `AshGrant.PermissionResolver` to provide permissions for actors.

### Simple resolver (returns strings)

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(nil, _context), do: []

  @impl true
  def resolve(actor, _context) do
    actor
    |> MyApp.Accounts.get_roles()
    |> Enum.flat_map(& &1.permissions)
  end
end
```

### Resolver with metadata (for debugging with `explain/4`)

Return `AshGrant.PermissionInput` structs to include source tracking:

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(nil, _context), do: []

  @impl true
  def resolve(actor, _context) do
    actor
    |> MyApp.Accounts.get_roles()
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

### Custom structs with the Permissionable protocol

Implement `AshGrant.Permissionable` for your own structs:

```elixir
defimpl AshGrant.Permissionable, for: MyApp.RolePermission do
  def to_permission_input(%MyApp.RolePermission{} = rp) do
    %AshGrant.PermissionInput{
      string: rp.permission_string,
      description: rp.label,
      source: "role:#{rp.role_name}"
    }
  end
end
```

### DON'T: Return nil from the resolver

Always return an empty list `[]` for unauthenticated or unknown actors.

## Default Policies

`default_policies` controls automatic policy generation:

| Value    | Read policy | Write policy |
|----------|-------------|--------------|
| `false`  | No          | No           |
| `true`   | Yes         | Yes          |
| `:always`   | Yes         | Yes          |
| `:read`  | Yes         | No           |
| `:write` | No          | Yes          |

Generated policies are equivalent to:

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

Use `:read` or `:write` when you need auto-generation for one type and
explicit control over the other.

## Instance Permissions

Instance permissions enable resource-sharing patterns (like Google Docs sharing).

```elixir
# Grant user access to a specific document
"document:doc_abc123:read:"     # Read access (no conditions)
"document:doc_abc123:*:"        # Full access

# Grant conditional instance access (ABAC)
"document:doc_abc123:update:draft"  # Update only when in draft status
```

For read actions, `FilterCheck` automatically builds `WHERE id IN (...)` filters
from instance permissions and combines them with RBAC scope filters using OR.

Instance permissions match against the resource's own key field only (`:id` by
default, or the field set by `instance_key`). They do **not** propagate to child
resources automatically — use `scope_through` for that.

### `instance_key` — match against a different field

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  instance_key :feed_id  # "feed:feed_abc:read:" → WHERE feed_id IN ('feed_abc')

  scope :always, true
end
```

### `scope_through` — propagate parent permissions to children

```elixir
# Parent: Feed (user has "feed:feed_abc:read:")
# Child: Post (belongs_to :feed)
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true

  scope :always, true
  scope_through :feed  # Posts where feed_id == "feed_abc" are now readable
end
```

Works with FilterCheck (reads), Check (writes), and CanPerform calculations.
Parent instance filters are combined with RBAC scopes using OR logic.

### DON'T: Assume instance permissions propagate to children automatically

```elixir
# User has "feed:feed_abc:read:"

# WRONG — this only grants access to the Feed record itself, not its Posts
# (unless Post has scope_through :feed)

# CORRECT — add scope_through to the child resource
ash_grant do
  scope_through :feed
end
```

## Field-Level Permissions

### Manual field policies (Mode A)

Write `field_policies` yourself using `AshGrant.field_check/1`:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  field_group :public, [:name, :department]
  field_group :sensitive, [:phone, :address], inherits: [:public]
  field_group :confidential, [:salary, :ssn], inherits: [:sensitive]
end

field_policies do
  field_policy [:salary, :ssn] do
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

### Auto-generated field policies (Mode B)

Set `default_field_policies: true` to auto-generate from field group definitions:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_field_policies true

  field_group :public, [:name, :department]
  field_group :sensitive, [:phone, :address], inherits: [:public]
  field_group :confidential, [:salary, :ssn], inherits: [:sensitive]
end
# field_policies block is generated automatically
```

### Field group inheritance

Field groups support inheritance. A group that inherits from another includes
all of the parent's fields plus its own:

```
:public        → [:name, :department]
:sensitive     → [:name, :department, :phone, :address]       (inherits :public)
:confidential  → [:name, :department, :phone, :address, :salary, :ssn]  (inherits :sensitive)
```

If an actor's permission uses the 4-part format (no field_group), all fields
are visible. The 5th part only restricts when explicitly present.

## Debugging

### `AshGrant.explain/4`

Returns an `AshGrant.Explanation` struct with details about an authorization decision:

```elixir
explanation = AshGrant.explain(MyApp.Post, :read, actor)

# Print human-readable output
explanation |> AshGrant.Explanation.to_string() |> IO.puts()
```

The explanation includes:
- All matching permissions with metadata (description, source)
- All evaluated permissions with match/no-match reasons
- Scope information and field groups
- The final decision and reason

### `AshGrant.Introspect`

Runtime introspection for building admin UIs and permission management:

```elixir
# Check if actor can perform an action
AshGrant.Introspect.can?(MyApp.Post, :read, actor)
# => :allow or :deny

# List all allowed actions
AshGrant.Introspect.allowed_actions(MyApp.Post, actor)

# Get all permissions with their status
AshGrant.Introspect.actor_permissions(MyApp.Post, actor)

# List all possible permissions for a resource
AshGrant.Introspect.available_permissions(MyApp.Post)
```

### `AshGrant.Info`

DSL introspection helpers for accessing configuration at runtime:

```elixir
AshGrant.Info.resolver(MyApp.Post)        # The configured resolver module
AshGrant.Info.scopes(MyApp.Post)          # List of scope definitions
AshGrant.Info.field_groups(MyApp.Post)    # List of field group definitions
AshGrant.Info.resource_name(MyApp.Post)   # The resource name string
```

## Policy Testing

### `mix ash_grant.verify`

Run policy configuration tests defined in YAML or Elixir files:

```bash
# Run all YAML tests in default directories
mix ash_grant.verify

# Run a specific file
mix ash_grant.verify path/to/test.yaml --verbose

# Run all tests in a directory
mix ash_grant.verify priv/policy_tests/

# Run an Elixir fixture file
mix ash_grant.verify test/support/policy_test_fixtures.ex
```

### YAML test format

```yaml
resource: MyApp.Blog.Post
tests:
  - name: "Editor can read all posts"
    actor:
      role: editor
      permissions:
        - "post:*:read:always"
    action: read
    expected: allow
```

## Common Mistakes

### Using `check()` for read actions

```elixir
# WRONG — check() returns true/false, doesn't filter results
policy action_type(:read) do
  authorize_if AshGrant.check()
end

# CORRECT
policy action_type(:read) do
  authorize_if AshGrant.filter_check()
end
```

### Missing the `:always` scope

Every resource with AshGrant should define a `:always` scope. Without it,
permissions like `"post:*:read:always"` will raise a runtime error because
the scope `"always"` cannot be resolved.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope :always, true  # Always include this
  scope :own, expr(author_id == ^actor(:id))
end
```

### Using `exists()` scopes without a data layer

The DB query fallback requires a data layer (e.g., AshPostgres). For resources
without a data layer, `exists()` conditions are replaced with `true` during
in-memory evaluation. Use `write:` to provide a direct-field expression:

```elixir
# For resources WITHOUT a data layer, use write: to provide an alternative
scope :same_org, expr(exists(org.users, id == ^actor(:id))),
  write: expr(org_id == ^actor(:org_id))
```

### Forgetting that deny-wins means no order dependency

Deny rules win regardless of where they appear in the permission list.
You cannot "override" a deny with a later allow.

```elixir
# These are equivalent — deny ALWAYS wins
["!post:*:delete:always", "post:*:*:always"]
["post:*:*:always", "!post:*:delete:always"]
```

### Using wrong permission format for instances

```elixir
# WRONG — 3-part format is legacy and may be ambiguous
"blog:post_abc123:read"

# CORRECT — use 4-part format with trailing colon for no-scope instance access
"blog:post_abc123:read:"
```

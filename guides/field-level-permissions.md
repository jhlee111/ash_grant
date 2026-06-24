# Field-Level Permissions

AshGrant supports column-level read authorization through **field groups**. Field groups control which fields are visible based on the actor's permissions, using Ash's native `field_policies` system.

## Field Group DSL

Define field groups with optional inheritance:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver

  scope :always, true

  # Root group — no inheritance (whitelist)
  field_group :public, [:name, :department, :position]

  # Inherits all fields from :public, adds phone and address
  field_group :sensitive, [:phone, :address], inherits: [:public]

  # Inherits all fields from :sensitive (which includes :public)
  field_group :confidential, [:salary, :email], inherits: [:sensitive]
end
```

### Blacklist Mode (`except`)

When a resource has many attributes, use `:always` with `except` to exclude specific fields instead of listing all visible ones:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope :always, true

  # All attributes except salary and ssn
  field_group :public, :all, except: [:salary, :ssn]

  # Child group adds back the excluded fields
  field_group :full, [:salary, :ssn], inherits: [:public]
end
```

`:always` expands to all resource attributes at compile time. `except` removes fields from that list. `:always` without `except` is also valid (expands to all attributes).

## Permission Strings with Field Groups

The 5th part of the permission string specifies the field group:

```elixir
"employee:*:read:always:public"         # See name, department, position only
"employee:*:read:always:sensitive"      # See public + phone, address
"employee:*:read:always:confidential"   # See all fields
"employee:*:read:always"               # No field_group → all fields visible
```

Fields not in the actor's field group are replaced with `%Ash.ForbiddenField{}`.

> #### Field groups are grant-only {: .warning}
>
> A field_group can only appear on an **allow** permission. A deny rule that
> carries a field_group (e.g. `"!employee:*:read:always:sensitive"`) is invalid —
> field-group access is positive-only, so column restrictions belong in the
> `field_group` definition (`inherits`/`except`/`mask`), not in a deny rule. In a
> hierarchy, "all fields except X" is already expressible as a positive grant of
> the lower group (here, `:public`). The `field_group_permissions` option
> (`:off` / `:warn` (default) / `:strict`) controls whether an invalid
> field-group deny is silent, logged, or raises — it never changes the
> (fail-closed) outcome.

## Mode A: Manual Field Policies

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

## Mode B: Auto-Generated Field Policies

Set `default_field_policies: true` to auto-generate field policies from field group definitions:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true
  default_field_policies true  # Auto-generates field_policies from field_groups

  scope :always, true

  field_group :public, [:name, :department, :position]
  field_group :sensitive, [:phone, :address], inherits: [:public]
  field_group :confidential, [:salary, :email], inherits: [:sensitive]
end
```

This also works with blacklist mode:

```elixir
field_group :public, :all, except: [:salary, :ssn]
field_group :full, [:salary, :ssn], inherits: [:public]
```

Auto-generates equivalent field policies with a catch-all `field_policy :*` that allows non-grouped fields.

## Field Group Inheritance

Inheritance follows a DAG (directed acyclic graph) — a child group includes all parent fields:

```
:public       → [:name, :department, :position]
:sensitive    → [:name, :department, :position, :phone, :address]
:confidential → [:name, :department, :position, :phone, :address, :salary, :email]
```

An actor with `confidential` permission can see everything that `sensitive` and `public` can see, plus their own fields.

## Field Masking

Instead of hiding fields entirely, you can show masked values. The
`mask:` option lists fields to mask at that group's level; `mask_with:`
is the function that produces the displayed value.

```elixir
field_group :sensitive, [:phone, :address],
  inherits: [:public],
  mask: [:phone, :address],
  mask_with: fn value, _field ->
    if is_binary(value), do: String.replace(value, ~r/./, "*"), else: "***"
  end
```

### `mask_with/2` signature

`mask_with` is a 2-arity function called once per masked field, per
record:

```elixir
@spec mask_with(value :: term(), field :: atom()) :: term()
```

- `value` — the attribute's current value on the record. May be `nil`.
- `field` — the attribute name as an atom. Useful for one function that
  masks multiple fields differently.

The return value replaces the attribute in the emitted record. It does
**not** have to be the same type as the input — returning a string
`"***"` for a numeric field is fine. The consumer should treat a
masked response as display-only.

```elixir
# Per-field logic via the second argument
mask_with: fn
  value, :phone when is_binary(value) ->
    "***-****-" <> String.slice(value, -4..-1)

  value, :email when is_binary(value) ->
    [_, domain] = String.split(value, "@", parts: 2)
    "***@" <> domain

  _value, _field ->
    "***"
end
```

### Masking rules

- **Not inherited.** Masking attaches to the group that declared it. A
  child group inheriting from a masked parent does *not* inherit the
  masking. An actor at the higher-level group sees raw values.
- **Allow-wins across groups.** If an actor holds two field groups and
  any one of them grants unmasked access to a field, that field is *not*
  masked. You don't have to reason about permission order — explicit
  unmasked access always wins.
- **4-part permissions skip masking entirely.** An actor with
  `"employee:*:read:always"` (no field_group) sees raw values, the same
  way they see all fields.

### Interaction with `%Ash.ForbiddenField{}`

Masking runs in a read-time `after_action` hook, *before* Ash's native
`restrict_field_access` step. If a field is outside the actor's field
groups entirely, it becomes `%Ash.ForbiddenField{}` during restriction
— masking does not touch those. `mask_with` never receives a
`%Ash.ForbiddenField{}` and never runs on fields the actor cannot see.

This means three levels exist:

| Actor access to field | Result |
|---|---|
| Not in any granted field group | `%Ash.ForbiddenField{}` |
| In a masked group only | `mask_with.(value, field)` — a displayable stand-in |
| In any unmasked group | raw value |

### Error handling

`mask_with` is called inside the query's `after_action` pipeline. If the
function raises, the read fails — the same way any other `after_action`
raise would. Keep the function total:

- Handle `nil` values explicitly if the column is nullable.
- Handle unexpected types defensively — return a generic mask rather
  than letting a pattern-match failure crash the read.
- Avoid DB calls inside `mask_with` — it runs per record and bypasses
  any batching.

```elixir
# DO: total and fast
mask_with: fn
  nil, _field -> nil
  value, _field when is_binary(value) -> String.replace(value, ~r/./, "*")
  _value, _field -> "***"
end

# DON'T: partial — raises on nil or non-binary values
mask_with: fn value, _ -> String.replace(value, ~r/./, "*") end
```

### Example behavior

| Actor Permission | phone | salary |
|-----------------|-------|--------|
| `...:public` | `%Ash.ForbiddenField{}` | `%Ash.ForbiddenField{}` |
| `...:sensitive` (with masking) | `"*************"` | `%Ash.ForbiddenField{}` |
| `...:confidential` | `"010-1234-5678"` | `80000` |
| `...` (4-part, no field_group) | `"010-1234-5678"` | `80000` |

### Masking functions and JSON

When an `AshGrant.Explanation` that references a masked field group is
serialized via `Jason.encode!/1`, the `mask_with` function value is
**stripped** — functions aren't JSON-representable. The rest of the
field group (name, fields, masked field names) round-trips cleanly.

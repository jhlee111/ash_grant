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

Instead of hiding fields entirely, you can show masked values:

```elixir
field_group :sensitive, [:phone, :address],
  inherits: [:public],
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

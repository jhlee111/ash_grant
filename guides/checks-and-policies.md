# Checks & Policies

AshGrant provides check modules that integrate with Ash's policy system, plus DSL options
for automatic policy generation.

## Check Types

### `filter_check/1` - For Read Actions

Returns a filter expression that limits query results to accessible records.
All scope types including `exists()` are fully supported (converted to SQL).

```elixir
policy action_type(:read) do
  authorize_if AshGrant.filter_check()
end
```

### `check/1` - For Write and Generic Actions

Returns `true` or `false` based on whether the actor has permission.
Simple scopes are evaluated in-memory. Scopes with relationship references
(`exists()` or dot-paths) automatically use a DB query to verify the scope.

```elixir
policy action_type([:create, :update, :destroy]) do
  authorize_if AshGrant.check()
end

# Generic actions require an explicit policy (not covered by default_policies)
policy action_type(:action) do
  authorize_if AshGrant.check()
end
```

#### Generic Actions

Generic actions (Ash actions with `type: :action`) use `Ash.ActionInput` instead
of `Ash.Query` or `Ash.Changeset`. `check/1` handles this correctly, including
tenant extraction from `action_input` for multi-tenant authorization.

Generic actions must be authorized by **specific action name** in the permission
string. Type wildcards do not apply because each generic action is individually
unique:

```elixir
# Grants access to the specific "ping" action only
"service_request:*:ping:always"

# Wildcard (*) grants access to all actions including generic ones
"service_request:*:*:always"
```

Since generic actions have no target record, only non-record scopes (like
`scope :always, true`) will pass scope evaluation.

### `CanPerform` Calculation - Per-Record UI Visibility

AshGrant generates per-record boolean calculations for UI visibility patterns
(show/hide buttons per row). These compile to SQL via `expression/2` (no N+1).

#### DSL Sugar (Recommended)

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope :always, true
  scope :own, expr(author_id == ^actor(:id))

  # Batch — generates :can_update? and :can_destroy?
  can_perform_actions [:update, :destroy]

  # Individual with custom name
  can_perform :read, name: :visible?
end
```

#### Explicit Module (Advanced)

For cases needing full control (e.g., custom `resource_name`):

```elixir
calculations do
  calculate :can_update?, :boolean,
    {AshGrant.Calculation.CanPerform, action: "update", resource: __MODULE__},
    public?: true
end
```

DSL-generated and explicit calculations coexist safely. If both declare the same
name, the explicit one takes precedence.

#### Querying and Templates

```elixir
# In your LiveView / controller
members =
  Member
  |> Ash.Query.load([:can_update?, :can_destroy?])
  |> Ash.read!(actor: current_user)

# In your template
<.button :if={member.can_update?}>Edit</.button>
<.button :if={member.can_destroy?}>Delete</.button>
```

#### DSL Options

| DSL | Description |
|-----|-------------|
| `can_perform_actions [:update, :destroy]` | Batch-generate `:can_<action>?` calculations (public) |
| `can_perform :action` | Generate a single calculation (default name: `:can_<action>?`) |
| `can_perform :action, name: :custom?` | Generate with a custom calculation name |
| `can_perform :action, public?: false` | Generate a private calculation |

#### Explicit Module Options

| Option | Type | Description |
|--------|------|-------------|
| `:action` | string | **Required.** Action name for permission matching |
| `:resource` | module | **Required.** The resource module (use `__MODULE__`) |
| `:resource_name` | string | Override resource name for permission matching |

The calculation handles RBAC scopes, instance permissions, deny-wins, and
multi-scope OR combination — all identical to `FilterCheck`.

## DSL Configuration

```elixir
ash_grant do
  resolver MyApp.PermissionResolver       # Required (or inherited from domain)
  default_policies true                   # Optional: auto-generate policies
  resource_name "custom_name"             # Optional: defaults to module name (e.g., MyApp.Blog.Post → "post")

  # Inline scopes
  scope :always, true
  scope :own, expr(owner_id == ^actor(:id))

  # Argument-based scope + argument resolver
  # (for multi-hop authorization — see the Argument-Based Scope guide)
  scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
  resolve_argument :center_id, from_path: [:order, :center_id]

  # UI visibility calculations
  can_perform_actions [:update, :destroy]
end
```

| Option | Type | Description |
|--------|------|-------------|
| `resolver` | module or function | **Required** (can be inherited from domain via `AshGrant.Domain`). Resolves permissions for actors |
| `default_policies` | boolean or atom | Auto-generate policies: `true`, `:always`, `:read`, or `:write` |
| `default_field_policies` | boolean | Auto-generate `field_policies` from `field_group` definitions |
| `can_perform_actions` | list of atoms | Batch-generate `CanPerform` calculations (e.g., `[:update, :destroy]`) |
| `resource_name` | string | Resource name for permission matching. Default: derived from module name (last segment, snake_cased). `MyApp.Blog.Post` → `"post"`, `MyApp.CustomerOrder` → `"customer_order"` |
| `instance_key` | atom | Field to match instance permission IDs against. Defaults to `:id` (primary key). See [Instance Key](permissions.md#instance-key) |

**Entities inside `ash_grant do ... end`**

| Entity | Description |
|--------|-------------|
| `scope :name, filter` | Named scope — see [Scopes](scopes.md) |
| `field_group :name, fields` | Field-level access group — see [Field-Level Permissions](field-level-permissions.md) |
| `can_perform :action` | Per-record boolean calculation |
| `scope_through :rel` | Propagate parent instance permissions to this resource |
| `resolve_argument :name, from_path: [...]` | Auto-populate an action argument from a relationship for argument-based scopes — see [Argument-Based Scope](argument-based-scope.md) |

### Default Policies Options

The `default_policies` option controls automatic policy generation:

| Value | Description |
|-------|-------------|
| `false` | No policies generated (default). You must define policies explicitly. |
| `true` or `:always` | Generate read, write, and generic action policies |
| `:read` | Only generate `filter_check()` policy for read actions |
| `:write` | Only generate `check()` policy for write and generic actions |

**Generated policies when `default_policies: true`:**

```elixir
policies do
  policy action_type(:read) do
    authorize_if AshGrant.filter_check()
  end

  policy action_type([:create, :update, :destroy]) do
    authorize_if AshGrant.check()
  end

  policy action_type(:action) do
    authorize_if AshGrant.check()
  end
end
```

### Per-Action Authorization with default_policies

When `default_policies: true` is set, the generated `check()` and `filter_check()` calls
automatically match the current action name against the actor's permission strings.
This means you get **per-action authorization** without writing explicit policies for each action.

For example, with these permissions:

```elixir
# Resolver returns:
["post:*:read:always", "post:*:update:own"]
```

The default policies will:
- Allow `:read` actions (matches `post:*:read:always`)
- Allow `:update` actions only on own records (matches `post:*:update:own`)
- Deny `:create` and `:destroy` actions (no matching permission)

Each action is individually checked against the permission strings — there is no
blanket "write" grant unless the actor has a wildcard permission like `post:*:*:always`.

If you need to map multiple Ash actions to the same permission, use the `action:` override:

```elixir
policy action([:read, :get_by_id, :list]) do
  authorize_if AshGrant.filter_check(action: "read")
end
```

## Advanced Usage

### Action Override

Map different Ash actions to the same permission:

```elixir
# Both :get_by_id and :list use "read" permission
policy action([:read, :get_by_id, :list]) do
  authorize_if AshGrant.filter_check(action: "read")
end
```

### Combining default_policies with Custom Policies

`default_policies` **adds** policies, it doesn't replace existing ones.
You can combine them:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  default_policies true  # Adds filter_check for read, check for write
end

policies do
  # This bypass runs BEFORE the default policies
  bypass actor_attribute_equals(:role, :admin) do
    authorize_if always()
  end

  # You can add more custom policies too
  policy action(:special_action) do
    authorize_if MyCustomCheck
  end
end
```

**Evaluation order:**

1. Bypass policies (if any)
2. Custom policies defined in `policies do`
3. Default policies from `default_policies: true`

### Legacy ScopeResolver

The `scope_resolver` option is deprecated. If configured alongside inline scopes, inline scope DSL is checked first and `scope_resolver` acts as a fallback for scopes not defined inline. An error is raised if a scope is found in neither. Migrate all scopes to inline `scope` definitions.

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  scope_resolver MyApp.LegacyScopeResolver  # Deprecated fallback

  # Inline scopes take priority
  scope :always, true
  scope :own, expr(author_id == ^actor(:id))
  # :legacy_scope will fall back to scope_resolver
end
```

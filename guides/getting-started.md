# Getting Started

This guide walks you through setting up AshGrant beyond the basics covered in the README's Quick Start.

## Module-Based Resolver (Production)

For production, extract the resolver to a module:

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(nil, _context), do: []

  @impl true
  def resolve(actor, _context) do
    # Load permissions from database
    actor
    |> MyApp.Accounts.get_user_permissions()
    |> Enum.map(& &1.permission_string)
  end
end
```

Then reference it in your resource:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  # ...
end
```

## Explicit Policies (Full Control)

For more control, disable `default_policies` and define policies explicitly:

```elixir
ash_grant do
  resolver MyApp.PermissionResolver
  # default_policies false (default)

  scope :always, true
  scope :own, expr(author_id == ^actor(:id))
end

policies do
  # Admin bypass
  bypass actor_attribute_equals(:role, :admin) do
    authorize_if always()
  end

  # Read actions: use filter_check (returns filtered results)
  policy action_type(:read) do
    authorize_if AshGrant.filter_check()
  end

  # Write actions: use check (returns true/false)
  policy action_type([:create, :update, :destroy]) do
    authorize_if AshGrant.check()
  end
end
```

### Resolver Context

The `context` parameter passed to your resolver contains:

| Key | Type | Description |
|-----|------|-------------|
| `:actor` | term | The actor performing the action |
| `:resource` | module | The Ash resource module |
| `:action` | Ash.Action.t | The action struct |
| `:tenant` | term \| nil | Current tenant (from query/changeset) |
| `:changeset` | Ash.Changeset.t \| nil | For write actions |
| `:query` | Ash.Query.t \| nil | For read actions |

**Example usage:**

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(actor, context) do
    base_permissions = get_role_permissions(actor)

    # Add instance permissions based on context
    case context do
      %{resource: MyApp.Document, action: %{name: :read}} ->
        shared_docs = get_shared_document_ids(actor)
        instance_perms = Enum.map(shared_docs, &"document:#{&1}:read:")
        base_permissions ++ instance_perms

      _ ->
        base_permissions
    end
  end
end
```

## Domain-Level DSL

When multiple resources share the same resolver and scopes, define them once at the domain level instead of repeating the same `ash_grant do` block in every resource.

**When to use:**
- 3+ resources in a domain share the same resolver and common scopes (`:always`, `:own`, etc.)
- You want a single place to change the resolver or add a scope for all resources

**When NOT to use:**
- Resources in a domain have very different resolvers or scope logic
- You only have 1–2 resources in the domain

### Setup

```elixir
defmodule MyApp.Blog do
  use Ash.Domain,
    extensions: [AshGrant.Domain]

  ash_grant do
    resolver MyApp.PermissionResolver

    scope :always, true
    scope :own, expr(author_id == ^actor(:id))
  end

  resources do
    resource MyApp.Blog.Post
    resource MyApp.Blog.Comment
  end
end
```

Resources inherit the domain's resolver and scopes automatically:

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    default_policies true
    # No resolver needed — inherited from domain
    # :always and :own scopes inherited from domain
    scope :published, expr(status == :published)  # Add resource-specific scopes
  end

  # ...
end
```

### Inheritance Rules

| Config | Resource defines it | Domain defines it | Result |
|--------|-------------------|-------------------|--------|
| resolver | Yes | Yes | **Resource wins** |
| resolver | No | Yes | Domain's resolver used |
| scope (same name) | Yes | Yes | **Resource wins** (override) |
| scope | No | Yes | Domain scope inherited |

Resource scopes can inherit from domain-defined parent scopes:

```elixir
# Domain defines :own scope
# Resource adds :own_draft that inherits from domain's :own
ash_grant do
  scope :own_draft, [:own], expr(status == :draft)
end
```

A compile error is raised if no resolver is found from either the resource or the domain.

## Resolver Patterns

### Permissions with Metadata

Return `AshGrant.PermissionInput` structs for enhanced debugging and `explain/4`:

```elixir
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(actor, _context) do
    actor
    |> get_roles()
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

### Custom Structs with Permissionable Protocol

Implement the `AshGrant.Permissionable` protocol for your custom structs:

```elixir
defmodule MyApp.RolePermission do
  defstruct [:permission_string, :label, :role_name]
end

defimpl AshGrant.Permissionable, for: MyApp.RolePermission do
  def to_permission_input(%MyApp.RolePermission{} = rp) do
    %AshGrant.PermissionInput{
      string: rp.permission_string,
      description: rp.label,
      source: "role:#{rp.role_name}"
    }
  end
end

# Then just return your structs from the resolver
defmodule MyApp.PermissionResolver do
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(actor, _context) do
    MyApp.Accounts.get_role_permissions(actor)
  end
end
```

## Tip: Relational Scopes

Once you're comfortable with the basics, AshGrant supports relationship-based scopes
using `exists()` and dot-path references. These work for both read and write actions:

```elixir
ash_grant do
  scope :team_member, expr(exists(team.memberships, user_id == ^actor(:id)))
  scope :same_center, expr(order.center_id == ^actor(:center_id))
end
```

For read actions, these compile to SQL (EXISTS subquery or JOIN). For write
actions, AshGrant automatically uses a DB query fallback. For multi-hop
write authorization, prefer the argument-based pattern — see the
[Argument-Based Scope guide](argument-based-scope.md). The
[Scopes guide](scopes.md) covers relational scopes in detail.

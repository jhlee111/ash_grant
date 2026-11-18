# AshGrant

[![CI](https://github.com/jhlee111/ash_grant/actions/workflows/ci.yml/badge.svg)](https://github.com/jhlee111/ash_grant/actions/workflows/ci.yml)
[![Hex version](https://img.shields.io/hexpm/v/ash_grant.svg)](https://hex.pm/packages/ash_grant)
[![Hex downloads](https://img.shields.io/hexpm/dt/ash_grant.svg)](https://hex.pm/packages/ash_grant)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/ash_grant)
[![License: MIT](https://img.shields.io/hexpm/l/ash_grant.svg)](https://github.com/jhlee111/ash_grant/blob/main/LICENSE)

Permission-based authorization extension for [Ash Framework](https://ash-hq.org/).

AshGrant connects three Ash-native concepts — **resources**, **actions**, and
**`expr()` scopes** — through a permission string (`[!]resource:instance_id:action:scope[:field_group]`).
Permissions resolve to native Ash filters and policy checks, with deny-wins semantics.

**Authorization:**
- **Domain-level DSL** — shared resolver and scopes inherited by all resources in a domain
- **Global scope registry** — declare `:own` / `:same_tenant` once with `use AshGrant.ScopeRegistry`, override per-resource or per-domain
- **Scope DSL** with `expr()` — row-level filters, scope inheritance, `^tenant()` support
- **Argument-based scopes** with `resolve_argument` — multi-hop authorization via action arguments populated from the resource's own relationships, with lazy loading
- **Field groups** — column-level read access with inheritance and masking
- **Instance permissions** — per-record sharing with optional scope conditions
- **Deny-wins evaluation** — deny rules always override allows, across type (`post:*:...`) and instance (`post:<id>:...`) grants

**UI Integration:**
- **`CanPerform` calculation** — per-record boolean for UI visibility (compiles to SQL), with DSL sugar (`can_perform_actions`, `can_perform`)

**Verification & Tooling:**
- **`explain/4`** — trace why authorization succeeded or failed
- **`Introspect`** — query actor permissions, available actions at runtime
- **Policy testing** — DSL and YAML-based config tests, no database required
- **`Permission.diagnostics/1`** — audit your own permission store for deprecated or dead grant syntax; also reported by `mix ash_grant.verify`
- **`PermissionValidation.check/2`** — check stored permission strings against your resources (unknown resource, action, scope or field group) before they go inert or raise at request time; ships as an Ash validation (`AshGrant.Validations.PermissionStrings`) and a CI task (`mix ash_grant.check_permissions`)

AshGrant handles permission evaluation, not role management. Resolve roles to
permission strings in your resolver.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```bash
mix igniter.install ash_grant
```

The installer adds the dependency and imports the `ash_grant` formatter rules into `.formatter.exs`.

Without Igniter, add `ash_grant` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_grant, "~> 0.22"}
  ]
end
```

## Quick Start

### 1. Add the Extension to Your Resource

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    # Resolver converts actor to permission strings
    resolver fn actor, _context ->
      case actor do
        %{role: :admin} -> ["post:*:*:always"]           # Full access
        %{role: :editor} -> [
          "post:*:read:always",                          # Read all posts
          "post:*:create:always",                        # Create posts
          "post:*:update:own"                         # Update own posts only
        ]
        %{role: :viewer} -> ["post:*:read:published"] # Read published only
        _ -> []
      end
    end

    default_policies true  # Auto-generates read/write policies

    # Scopes define row-level filters (referenced by permission strings)
    scope :always, true
    scope :own, expr(author_id == ^actor(:id))
    scope :published, expr(status == :published)
  end

  # ... attributes, actions, etc.
end
```

**How it works:**
1. Actor (`%{role: :editor, id: "user_123"}`) is passed to the resolver
2. Resolver returns permission strings like `"post:*:update:own"`
3. Permission `post:*:update:own` references scope `:own`
4. Scope `:own` adds filter `author_id == actor.id` to queries

### 2. Use It

```elixir
# Editor can read all posts
editor = %{id: "user_123", role: :editor}
Post |> Ash.read!(actor: editor)

# Editor can only update their own posts
Ash.update!(post, %{title: "New Title"}, actor: editor)
# => Succeeds if post.author_id == "user_123"
# => Fails if post.author_id != "user_123"

# Viewer can only read published posts
viewer = %{id: "user_456", role: :viewer}
Post |> Ash.read!(actor: viewer)
# => Returns only posts where status == :published
```

## Guides

- **[Getting Started](guides/getting-started.md)** — Module-based resolvers, explicit policies, domain-level DSL, resolver patterns
- **[Permissions](guides/permissions.md)** — Permission format, wildcards, RBAC, instance permissions, instance_key, scope_through, deny-wins, multi-grant OR-composition
- **[Scopes](guides/scopes.md)** — Scope DSL, inheritance, combination rules, multi-tenancy, relational scopes, business examples
- **[Scope Naming Convention](guides/scope-naming-convention.md)** — Predicate naming, sentence test, RBAC/ABAC patterns, AND/OR composition
- **[Argument-Based Scope](guides/argument-based-scope.md)** — Multi-hop authorization via action arguments + resource-local lazy loading, avoids DB-query fallback
- **[Advanced Patterns](guides/advanced-patterns.md)** — Real-world recipes combining `resolve_argument` and `scope_through` (multi-hop writes, parent-shared children, both together)
- **[Field-Level Permissions](guides/field-level-permissions.md)** — Field groups, whitelist/blacklist modes, inheritance, masking
- **[Checks & Policies](guides/checks-and-policies.md)** — Check types, CanPerform calculations, DSL configuration, default_policies
- **[Debugging & Introspection](guides/debugging-and-introspection.md)** — explain/4, permission introspection, identifier-based lookups, expression stringification
- **[Policy Testing](guides/policy-testing.md)** — DSL and YAML tests, mix tasks, export/import
- **[Migration Guide](guides/migration.md)** — Moving off deprecated `write:`, `scope_resolver`, and `owner_field`

## Architecture

```
                    Ash Policy Check                Ash Calculation
                          |                              |
            +-------------+-------------+--------+  +---v-----------+
            |                           |        |  | CanPerform    |
      +-----v-----+              +------v------+ |  | (UI booleans) |
      |  Check    |              | FilterCheck | |  +---+-----------+
      | (writes)  |              |  (reads)    | |      |
      +-----+-----+              +------+------+ |      |
            |                           |        |      |
            +-----------+---------------+-+------+------+
                        |
            +-----------v-----------+
            | PermissionResolver    |
            | (actor -> permissions)|
            +-----------+-----------+
                        |
            +-----------v-----------+
            | Evaluator             |
            | (deny-wins matching)  |
            +-----------+-----------+
                        |
            +-----------v-----------+
            | Scope DSL / Field     |
            | Groups / Resolver     |
            +-----------------------+
```

## Background

I started AshGrant at the end of 2025 for my own production app. Most of it was
built with Claude Code through TDD: I described the behaviour I needed, the agent
wrote the tests and the implementation, and I reviewed the results.

In November 2026, [Conor Sinclair (@C-Sinclair)](https://github.com/C-Sinclair)
stepped in as a co-maintainer. I'm grateful to him for that.

Issues and PRs are welcome.

Thanks to Zach Daniel, the Ash core team, and the Elixir community. Ash's
well-documented abstractions are what made this project possible.

## License

MIT License - see [LICENSE](LICENSE) for details.

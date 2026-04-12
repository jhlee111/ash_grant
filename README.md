# AshGrant

Permission-based authorization extension for [Ash Framework](https://ash-hq.org/).

AshGrant connects three Ash-native concepts — **resources**, **actions**, and
**`expr()` scopes** — through a permission string (`[!]resource:instance_id:action:scope[:field_group]`).
Permissions resolve to native Ash filters and policy checks, with deny-wins semantics.

**Authorization:**
- **Domain-level DSL** — shared resolver and scopes inherited by all resources in a domain
- **Scope DSL** with `expr()` — row-level filters, scope inheritance, `^tenant()` support
- **Field groups** — column-level read access with inheritance and masking
- **Instance permissions** — per-record sharing with optional scope conditions
- **Deny-wins evaluation** — deny rules always override allows

**UI Integration:**
- **`CanPerform` calculation** — per-record boolean for UI visibility (compiles to SQL), with DSL sugar (`can_perform_actions`, `can_perform`)

**Verification & Tooling:**
- **`explain/4`** — trace why authorization succeeded or failed
- **`Introspect`** — query actor permissions, available actions at runtime
- **Policy testing** — DSL and YAML-based config tests, no database required

AshGrant handles permission evaluation, not role management. Resolve roles to
permission strings in your resolver.

## Installation

Add `ash_grant` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_grant, "~> 0.13"}
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
- **[Permissions](guides/permissions.md)** — Permission format, wildcards, RBAC, instance permissions, instance_key, scope_through, deny-wins
- **[Scopes](guides/scopes.md)** — Scope DSL, inheritance, combination rules, multi-tenancy, relational scopes, business examples
- **[Scope Naming Convention](guides/scope-naming-convention.md)** — Predicate naming, sentence test, RBAC/ABAC patterns, AND/OR composition
- **[Argument-Based Scope](guides/argument-based-scope.md)** — Multi-hop authorization via action arguments + resource-local lazy loading, avoids DB-query fallback
- **[Field-Level Permissions](guides/field-level-permissions.md)** — Field groups, whitelist/blacklist modes, inheritance, masking
- **[Checks & Policies](guides/checks-and-policies.md)** — Check types, CanPerform calculations, DSL configuration, default_policies
- **[Debugging & Introspection](guides/debugging-and-introspection.md)** — explain/4, permission introspection, write: option, scope descriptions
- **[Policy Testing](guides/policy-testing.md)** — DSL and YAML tests, mix tasks, export/import

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

## Disclosure

  I've been a developer for about six years. I became interested in Elixir, Phoenix, and Ash a couple of years ago, but only started actually building with
  them about four months ago. This library was born out of my own needs, and honestly, my skills in this ecosystem aren't at the level where I'd normally
  attempt building something like this.

  Most of AshGrant was developed through TDD with Claude Code—I described what I needed, Claude Code wrote the tests and implementation, and I reviewed the
  results. I treated it like any third-party library: if the tests pass and the code looks reasonable, I use it. I haven't read every line of code in detail,
  so I can't guarantee everything works perfectly.

  I'm using this in production because I need it now, but please consider this more as a **proof of concept**—a proposal for how authorization could be handled
   in Ash. I'm sharing this publicly in hopes that it can be a starting point. If others find it useful and want to contribute, we could build something better
   together.

  If you have suggestions or find issues, please feel free to open an issue or submit a PR—contributions are very welcome.

  What made this possible is how exceptionally well-documented Elixir and Ash are. The clear abstractions—DSLs, Domains, Resources, Extensions—gave me a
  precise vocabulary to communicate my requirements to an LLM. These well-defined concepts provided both the courage to start and the foundation to actually
  ship something I use in production.

  I'm deeply grateful to Zach for creating Ash Framework, the Ash Core Team, all the contributors, and the broader Elixir community. We have something special
  here.

## License

MIT License - see [LICENSE](LICENSE) for details.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-01-01

### Added

- **Unified Permission Format**: New 4-part permission syntax `resource:instance_id:action:scope`
  - RBAC permissions: `blog:*:read:all` (instance_id = `*`)
  - Instance permissions: `blog:post_abc123:read:` (specific instance)
  - Backward compatible with legacy 2-part and 3-part formats
- **Scope DSL**: Define scopes inline within resources using the `scope` entity
  - `scope :all, true`
  - `scope :own, expr(author_id == ^actor(:id))`
  - `scope :published, expr(status == :published)`
  - Scope inheritance with `scope :own_draft, [:own], expr(status == :draft)`
- **Deny-wins semantics**: Deny rules always override allow rules
- **Wildcard matching**: `*` for resources/actions, `read*` for action prefixes
- **Two check types**:
  - `AshGrant.filter_check/1` for read actions (returns filter expression)
  - `AshGrant.check/1` for write actions (returns true/false)
- **Property-based testing**: 34 property tests for edge case discovery
- **Comprehensive test coverage**: 113 total tests (34 properties + 79 unit tests)

### DSL Configuration

```elixir
ash_grant do
  resolver MyApp.PermissionResolver       # Required
  resource_name "custom_name"             # Optional
  owner_field :user_id                    # Optional

  # Inline scope definitions (new!)
  scope :all, true
  scope :own, expr(author_id == ^actor(:id))
  scope :published, expr(status == :published)
end
```

### Behaviours

- `AshGrant.PermissionResolver` - Resolves permissions for actors
- `AshGrant.ScopeResolver` - Legacy: translates scopes to Ash filters (deprecated in favor of scope DSL)

### Modules

| Module | Description |
|--------|-------------|
| `AshGrant` | Main extension with `check/1` and `filter_check/1` |
| `AshGrant.Permission` | Permission parsing and matching |
| `AshGrant.Evaluator` | Deny-wins permission evaluation |
| `AshGrant.Info` | DSL introspection helpers |
| `AshGrant.Check` | SimpleCheck for write actions |
| `AshGrant.FilterCheck` | FilterCheck for read actions |

[0.1.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.1.0

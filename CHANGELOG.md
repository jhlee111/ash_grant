# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Instance Permissions with Scopes (ABAC)**: Instance permissions now support scope conditions
  - `doc:doc_123:update:draft` - Update only when document is in draft status
  - `doc:doc_123:read:business_hours` - Access only during business hours
  - `invoice:inv_456:approve:small_amount` - Approve only below threshold
  - Scopes are now treated as "authorization conditions" rather than just "record filters"
  - Empty scopes (trailing colon) remain backward compatible ("no conditions")
- **New Evaluator Functions**:
  - `get_instance_scope/3` - Get the scope from a matching instance permission
  - `get_all_instance_scopes/3` - Get all scopes from matching instance permissions
- **Context Injection for Testable Scopes**: Scopes can now use `^context(:key)` for injectable values
  - `scope :today_injectable, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))`
  - `scope :threshold, expr(amount < ^context(:max_amount))`
  - Enables deterministic testing of temporal and parameterized scopes
  - Values are passed via `Ash.Query.set_context(%{reference_date: ~D[2025-01-15]})`

### Changed

- **Documentation**: Clarified that scope represents an "authorization condition" that can apply
  to both RBAC and instance permissions, enabling full ABAC (Attribute-Based Access Control)

## [0.2.1] - 2025-01-01

### Added

- **Multi-tenancy Support**: Full support for Ash's `^tenant()` template in scope expressions
  - `scope :same_tenant, expr(tenant_id == ^tenant())` now works correctly
  - Tenant context is passed through to `Ash.Expr.eval/2`
  - Smart fallback evaluation when Ash.Expr.eval returns `:unknown`
- **TenantPost test resource**: Demonstrates multi-tenancy scope patterns

### Deprecated

- **`owner_field` DSL option**: This option is deprecated and will be removed in v0.3.0.
  Use explicit scope expressions instead:
  ```elixir
  # Instead of: owner_field :author_id
  # Use: scope :own, expr(author_id == ^actor(:id))
  ```
  The fallback evaluation now extracts the field from the scope expression directly.

### Improved

- **Fallback expression evaluation**: Smarter handling when `Ash.Expr.eval` can't evaluate
  - Analyzes filter to detect `^tenant()` and `^actor()` references
  - Automatically extracts actor field from the filter expression (no `owner_field` needed)
  - Proper tenant isolation for write actions

## [0.2.0] - 2025-01-01

### Added

- **Default Policies**: New `default_policies` DSL option to auto-generate standard policies
  - `default_policies true` or `:all` - Generate both read and write policies
  - `default_policies :read` - Only generate filter_check policy for read actions
  - `default_policies :write` - Only generate check policy for write actions
  - Eliminates boilerplate policy declarations for common use cases
- **Transformer**: `AshGrant.Transformers.AddDefaultPolicies` generates policies at compile time
- **Info helper**: `AshGrant.Info.default_policies/1` to query the setting

### Improved

- **Expression evaluation**: Now uses `Ash.Expr.eval/2` for proper Ash expression handling
  - Full support for all Ash expression operators (not just `==` and `in`)
  - Proper actor template resolution (`^actor(:id)`, `^actor(:tenant_id)`, etc.)
  - Proper tenant template resolution (`^tenant()`)
  - Handles nested actor paths automatically
- **Code quality**: Removed ~60 lines of custom expression handling in favor of Ash built-ins

### DSL Configuration (Updated)

```elixir
ash_grant do
  resolver MyApp.PermissionResolver       # Required
  default_policies true                   # NEW: auto-generate policies
  resource_name "custom_name"             # Optional

  scope :all, true
  scope :own, expr(author_id == ^actor(:id))
  scope :published, expr(status == :published)
end
```

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
- **Comprehensive test coverage**: 211 total tests (19 doctests + 34 properties + 158 unit tests)

### DSL Configuration

```elixir
ash_grant do
  resolver MyApp.PermissionResolver       # Required
  resource_name "custom_name"             # Optional

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

[0.2.1]: https://github.com/jhlee111/ash_grant/releases/tag/v0.2.1
[0.2.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.2.0
[0.1.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.1.0

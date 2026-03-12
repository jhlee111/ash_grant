# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (BREAKING)

- **`field_group` DSL redesign** (#40): Removed positional argument ambiguity between `inherits` and `fields`
  - **BREAKING: `inherits` is now keyword-only**: `field_group :name, [:parents], [:fields]` no longer works. Use `field_group :name, [:fields], inherits: [:parents]` instead.
  - **BREAKING: `[:*]` replaced by `:all`**: Use `field_group :name, :all` instead of `field_group :name, [:*]` (deprecated `[:*]` still works with a warning, will be removed in v1.0.0)
  - **New `:all` syntax**: `field_group :admin, :all` — all resource attributes
  - **Blacklist mode**: `field_group :public, :all, except: [:salary, :ssn]`
  - **Combined**: `field_group :editor, :all, except: [:admin_notes], inherits: [:base]`
  - **Most common pattern unchanged**: `field_group :public, [:name, :department]` works as before

#### Migration Guide

```elixir
# Before (v0.9.0)
field_group :public, [], [:*], except: [:salary, :ssn]
field_group :sensitive, [:public], [:phone, :address]
field_group :confidential, [:sensitive], [:salary, :email]

# After (v0.10.0)
field_group :public, :all, except: [:salary, :ssn]
field_group :sensitive, [:phone, :address], inherits: [:public]
field_group :confidential, [:salary, :email], inherits: [:sensitive]
```

### Deprecated

- **`[:*]` wildcard syntax**: Use `:all` instead. `[:*]` still works but emits a compile-time deprecation warning. Will be removed in v1.0.0.

## [0.9.0] - 2026-03-12

### Added

- **`field_group` `except` option (blacklist mode)**: Use `[:*]` wildcard with `except` to exclude specific fields instead of listing all visible ones. Useful for resources with many attributes where only a few are sensitive. (#36)
  - `field_group :public, [], [:*], except: [:salary, :ssn]` — all attributes except salary and ssn
  - `[:*]` without `except` expands to all resource attributes
  - Compile-time validations: `except` requires `[:*]`, except fields must exist, masked fields cannot be in `except`
  - New transformer `AshGrant.Transformers.ResolveFieldGroupExcept` resolves wildcards before downstream validation

## [0.8.1] - 2026-03-11

### Fixed

- **DB query fallback now handles `Ash.Query.Call` (dot-path expressions)**: Expressions like `expr(order.center_id in ^actor(:ids))` are now correctly detected as relationship references and trigger the DB query fallback for write actions. Previously only `exists()` expressions were detected. (#33)
- **Pass `tenant:` to `Ash.exists?/2` calls**: Multitenanted resources no longer fail silently during DB query fallback write checks. (#33)

## [0.8.0] - 2026-03-11

### Added

- **DB query fallback for relational write scopes**: Scopes using `exists()` or dot-path references now work correctly for write actions (create, update, destroy) without requiring a `write:` option. When a scope has relationship references and no explicit `write:` override, `AshGrant.Check` automatically queries the database using the read scope expression. (#28)
  - **Update/destroy**: Queries DB to check if the existing record matches the read scope
  - **Create**: Splits the filter — direct-attribute conditions are evaluated in-memory, relationship conditions are verified via DB query on parent resources
  - `write:` option still works as an explicit override (backward compatible)
  - Resources without a data layer fall back to in-memory evaluation (existing behavior)

### Removed

- **Compile-time warning for relationship scopes without `write:`**: The warning is no longer needed since the DB query fallback handles these cases automatically. (#28)

## [0.7.0] - 2026-03-11

### Added

- **Dual read/write scope (`write:` option)**: Scopes can now provide a separate expression for write actions via the `write:` option. This solves the authorization bypass where `exists()` and dot-path scopes were silently replaced with `true` during in-memory evaluation for write actions. (#26)
  - `write: expr(...)` — direct-field expression for in-memory evaluation
  - `write: false` — explicitly deny writes with this scope
  - `write: true` — allow all writes with this scope (no filtering)
  - Falls back to `filter` when `write:` is omitted (backward compatible)
  - Inheritance support: child scopes inherit parent's `write:` expression; `write: false` propagates to children
  - New `AshGrant.Info.resolve_write_scope_filter/3` function for write scope resolution

### Changed

- **Compile-time warning for relationship scopes**: The warning for `exists()`/dot-path scopes now fires regardless of `default_policies` setting and also detects dot-path references (not just `exists()`). The warning is suppressed when a `write:` option is provided. (#26)
- **`AshGrant.Check` uses write scope resolution**: Write actions now resolve scopes via `resolve_write_scope_filter/3` instead of `resolve_scope_filter/3`, using the `write:` expression when available. (#26)

## [0.6.1] - 2026-03-01

### Fixed

- **Bulk operations crash with `exists()` scopes**: `Ash.bulk_create/4` (and bulk_update/bulk_destroy) crashed with `nil.persisted(:relationships_by_name)` when the resource had an `exists()` scope expression. The fix replaces `exists()` nodes with `true` before in-memory evaluation. Attribute-based conditions in the same scope are still enforced. (#23)

### Added

- **Compile-time warning for `exists()` scopes**: Resources with `default_policies` including write actions now emit a warning when scopes contain `exists()`, informing users that the relational condition is not enforced for writes
- **Documentation**: Added "Relational Scopes" section to README and moduledocs explaining the `exists()` limitation for write actions

## [0.6.0] - 2026-02-19

### Added

- **Field-Level Permissions**: Column-level read authorization via field groups
  - `field_group` DSL entity with inheritance (DAG-based) and masking support
  - 5-part permission format: `resource:instance:action:scope:field_group` (backward compatible with 4-part)
  - `AshGrant.FieldCheck` - SimpleCheck for Ash `field_policies` integration
  - `AshGrant.field_check/1` - Public API for use in manual `field_policies` (Mode A)
  - `default_field_policies: true` - Auto-generate `field_policies` from `field_group` definitions (Mode B)
  - Field group inheritance: child groups include all parent fields
  - Field masking with allow-wins semantics via `mask` and `mask_with` options

- **New Modules**:
  - `AshGrant.Dsl.FieldGroup` - Struct and DSL entity for field group definitions
  - `AshGrant.FieldCheck` - SimpleCheck for field-level authorization
  - `AshGrant.Preparations.ApplyMasking` - Runtime masking via `after_action` hook
  - `AshGrant.Transformers.AddFieldPolicies` - Auto-generates `field_policies` from field groups
  - `AshGrant.Transformers.AddMaskingPreparation` - Auto-registers masking preparation
  - `AshGrant.Transformers.ValidateFieldGroups` - Compile-time validation (duplicates, cycles, missing parents)

- **New Evaluator Functions**:
  - `get_field_group/3` - Get first matching field group from permissions
  - `get_all_field_groups/3` - Get all matching field groups (union for field access)

- **New Info Functions**:
  - `field_groups/1` - Get all field group definitions for a resource
  - `get_field_group/2` - Get a specific field group by name
  - `resolve_field_group/2` - Resolve a field group with inheritance
  - `default_field_policies/1` - Get the `default_field_policies` setting
  - `fetch_permissions/3` - Shared permission resolution helper

- **Introspect Updates**: `actor_permissions`, `available_permissions`, `can?`, and `allowed_actions` now include `field_groups` / `field_group` in their responses

- **Explainer & PolicyExport**: Field group information in `explain/4` output, Markdown tables, and Mermaid diagrams

### Changed

- **Permission format**: Extended from 4-part to optional 5-part with `field_group`
- **Transformer ordering**: `ValidateFieldGroups` now explicitly runs before `AddFieldPolicies` and `AddMaskingPreparation`

## [0.5.0] - 2026-01-21

### Added

- **Policy Configuration Testing**: DSL-based testing framework for verifying policy configurations without a database
  - `AshGrant.PolicyTest` - Main module with `use` macro for defining policy tests
  - `assert_can/2,3` and `assert_cannot/2,3` assertion macros
  - `resource/1`, `actor/2`, `describe/2`, `test/2` DSL macros
  - `AshGrant.PolicyTest.Runner` - Test execution with summary statistics
  - `AshGrant.PolicyTest.Result` - Result struct with timing information

- **YAML Policy Tests**: Alternative format for non-Elixir developers
  - `AshGrant.PolicyTest.YamlParser` - Parse and run YAML test files
  - `AshGrant.PolicyTest.YamlExporter` - Export DSL tests to YAML
  - `AshGrant.PolicyTest.DslGenerator` - Generate DSL code from YAML

- **Policy Export**: Export policy configurations to documentation formats
  - `AshGrant.PolicyExport.Mermaid` - Generate Mermaid flowchart diagrams
  - `AshGrant.PolicyExport.Markdown` - Generate Markdown documentation

- **Mix Tasks**: CLI tools for policy testing and export
  - `mix ash_grant.verify` - Run policy configuration tests
  - `mix ash_grant.export` - Export policies to YAML/Mermaid/Markdown
  - `mix ash_grant.import` - Convert YAML to Elixir DSL

### Dependencies

- Added `yaml_elixir ~> 2.9` as optional dependency for YAML support

## [0.4.1] - 2026-01-21

### Added

- **SAT Solver Optimization Callbacks**: Implements `Ash.Policy.Check` optional callbacks for smarter authorization decisions
  - `simplify/2` - Returns ref unchanged (permissions are runtime-resolved)
  - `implies?/3` - Returns `true` when check refs have identical module and options
  - `conflicts?/3` - Returns `false` (deny-wins is handled at evaluation time)
  - Enables the authorizer to reach decisions with fewer variables in conditions
  - Suggested by Jonatan Männchen (Ash contributor)

### Changed

- **Version management**: Removed hardcoded version numbers from documentation
  - README.md now references GitHub without specific tag (always uses latest)
  - `@moduledoc` installation section now links to README
  - Single source of truth: `mix.exs @version`

- **Deprecation timeline**: Extended `owner_field` deprecation from v0.3.0 to v1.0.0
  - Affects: `dsl.ex`, `info.ex`, `validate_scopes.ex`, `CHANGELOG.md`

## [0.4.0] - 2026-01-05

### Added

- **Permission Introspection Module**: New `AshGrant.Introspect` module for runtime permission queries
  - `actor_permissions/3` - Admin UI: Display all permissions with their status for an actor
  - `available_permissions/1` - Permission management: List all possible permission combinations
  - `can?/4` - Debugging: Simple check returning `:allow` or `:deny` with details
  - `allowed_actions/3` - API response: List allowed actions (with optional `:detailed` mode)
  - `permissions_for/3` - Raw access to permission strings from resolver
  - All functions support `:context` option for resolver context

- **Instance Permission Read Support**: Instance permissions now work with read actions (`filter_check/1`)
  - `AshGrant.Evaluator.get_matching_instance_ids/3` extracts instance IDs from permissions
  - `FilterCheck` combines RBAC scopes with instance ID filters using OR logic
  - Enables Google Docs-style sharing where specific resources are shared with specific users
  - Example: `"doc:doc_abc123:read:"` allows reading the specific document

## [0.3.1] - 2025-01-05

### Added

- **Scope Descriptions**: Optional `description` field for scopes in the DSL
  - `scope :own, [], expr(author_id == ^actor(:id)), description: "Records owned by the current user"`
  - `AshGrant.Info.scope_description/2` to retrieve scope descriptions programmatically
  - Descriptions are displayed in `explain/4` output for better debugging

- **Authorization Debugging with `explain/4`**: New `AshGrant.explain/4` function for debugging authorization decisions
  - Returns `AshGrant.Explanation` struct with detailed decision info
  - Shows matching permissions with metadata (description, source)
  - Shows all evaluated permissions with match/no-match reasons
  - Includes scope information from both permissions and DSL definitions
  - `AshGrant.Explanation.to_string/2` for human-readable output with ANSI colors

- **New Modules**:
  - `AshGrant.Explanation` - Struct for authorization decision explanations
  - `AshGrant.Explainer` - Builds detailed authorization explanations

## [0.3.0] - 2025-01-04

### Added

- **Permission Metadata**: `AshGrant.PermissionInput` struct for permissions with metadata
  - `description` - Human-readable description of the permission
  - `source` - Where the permission came from (e.g., "role:admin")
  - `metadata` - Additional arbitrary metadata as a map

- **Permissionable Protocol**: `AshGrant.Permissionable` protocol for converting custom structs to permissions
  - Implement for your own structs to return them directly from resolvers
  - Default implementations for `BitString`, `PermissionInput`, and `Permission`

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

## [0.2.2] - 2025-01-02

### Fixed

- **Documentation**: Removed deprecated `owner_field` from README examples
- **Documentation**: Added note that instance permissions currently only work with write actions (`check/1`)

### Changed

- **Tests**: Enabled previously skipped "own" scope update tests that now pass

## [0.2.1] - 2025-01-01

### Added

- **Multi-tenancy Support**: Full support for Ash's `^tenant()` template in scope expressions
  - `scope :same_tenant, expr(tenant_id == ^tenant())` now works correctly
  - Tenant context is passed through to `Ash.Expr.eval/2`
  - Smart fallback evaluation when Ash.Expr.eval returns `:unknown`
- **TenantPost test resource**: Demonstrates multi-tenancy scope patterns

### Deprecated

- **`owner_field` DSL option**: This option is deprecated and will be removed in v1.0.0.
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

[Unreleased]: https://github.com/jhlee111/ash_grant/compare/v0.8.1...HEAD
[0.8.1]: https://github.com/jhlee111/ash_grant/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/jhlee111/ash_grant/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/jhlee111/ash_grant/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/jhlee111/ash_grant/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.6.0
[0.5.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.5.0
[0.4.1]: https://github.com/jhlee111/ash_grant/releases/tag/v0.4.1
[0.4.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.4.0
[0.3.1]: https://github.com/jhlee111/ash_grant/releases/tag/v0.3.1
[0.3.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.3.0
[0.2.2]: https://github.com/jhlee111/ash_grant/releases/tag/v0.2.2
[0.2.1]: https://github.com/jhlee111/ash_grant/releases/tag/v0.2.1
[0.2.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.2.0
[0.1.0]: https://github.com/jhlee111/ash_grant/releases/tag/v0.1.0

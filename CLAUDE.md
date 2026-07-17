# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AshGrant is a permission-based authorization extension for Ash Framework. It provides an Apache Shiro-inspired permission system with deny-wins semantics, supporting both RBAC and resource-instance permissions.

## Language Policy

**All repository content must be written in English**, including:
- README.md, CHANGELOG.md, and all documentation
- Code comments and docstrings (@moduledoc, @doc)
- Commit messages and PR descriptions
- CLAUDE.md instructions

## Common Commands

```bash
# Run tests (auto-creates and migrates test DB)
mix test

# Run a single test file
mix test test/ash_grant/permission_test.exs

# Run a specific test by line number
mix test test/ash_grant/permission_test.exs:42

# Linting
mix credo

# Type checking
mix dialyzer

# Generate documentation
mix docs

# Database management (test only)
mix ecto.setup    # Create and migrate
mix ecto.reset    # Drop, create, and migrate

# Policy configuration testing (NOT mix test)
mix ash_grant.verify test/support/policy_test_fixtures.ex
mix ash_grant.verify priv/policy_tests/           # Run all YAML tests
mix ash_grant.verify path/to/test.yaml --verbose  # Verbose output
```

## Architecture

### Core Modules

- **`AshGrant`** (`lib/ash_grant.ex`) - Main extension module, exports `check/1` and `filter_check/1`
- **`AshGrant.Dsl`** (`lib/ash_grant/dsl.ex`) - Spark DSL definition for the `ash_grant` block
- **`AshGrant.Permission`** (`lib/ash_grant/permission.ex`) - Parses and matches permission strings (`resource:instance_id:action:scope`). Also exposes `diagnostics/1`, which reports deprecated/dead grant syntax for offline auditing (never affects authorization)
- **`AshGrant.Evaluator`** (`lib/ash_grant/evaluator.ex`) - Implements deny-wins evaluation logic

### Policy Checks

- **`AshGrant.Check`** (`lib/ash_grant/checks/check.ex`) - SimpleCheck for write actions (returns true/false)
- **`AshGrant.FilterCheck`** (`lib/ash_grant/checks/filter_check.ex`) - FilterCheck for read actions (returns filter expression)
- **`AshGrant.PermissionValidation`** (`lib/ash_grant/permission_validation.ex`) - Validates resolved permissions and signals invalid deny+field_group combinations per the `field_group_permissions` mode (`:off`/`:warn`/`:strict`); never changes the authorization outcome
- **`AshGrant.FieldFilterCheck`** (`lib/ash_grant/checks/field_filter_check.ex`) - FilterCheck for **per-record** field-group visibility; generated into `field_policies` by `AddFieldPolicies`. Builds a per-row predicate from `Evaluator.field_group_grants/5` (a field is visible on some records, `%Ash.ForbiddenField{}` on others)
- **`AshGrant.FieldCheck`** (`lib/ash_grant/checks/field_check.ex`) - legacy action-wide SimpleCheck for field groups (superseded by `FieldFilterCheck` in generation; still present)

### Calculations

- **`AshGrant.Calculation.CanPerform`** (`lib/ash_grant/calculations/can_perform.ex`) - Per-record boolean calculation for UI visibility (mirrors FilterCheck logic, compiles to SQL)

### Argument-Based Scope Support

- **`AshGrant.ArgumentAnalyzer`** (`lib/ash_grant/argument_analyzer.ex`) - Compile-time AST walker that maps `%{arg_name => [scopes_using_it]}` for a resource's scopes
- **`AshGrant.Changes.ResolveArgument`** (`lib/ash_grant/changes/resolve_argument.ex`) - Runtime change that lazily loads a relationship path and sets an action argument, but only when an in-play permission uses a scope that references the argument

### Behaviours

- **`AshGrant.PermissionResolver`** - Behaviour for fetching actor permissions
- **`AshGrant.ScopeResolver`** - Legacy behaviour for custom scope resolution

### Domain-Level Extension

- **`AshGrant.Domain`** (`lib/ash_grant/domain.ex`) - Domain extension for shared resolver/scope inheritance
- **`AshGrant.Domain.Dsl`** (`lib/ash_grant/domain/dsl.ex`) - Domain DSL section (resolver + scope entities)
- **`AshGrant.Domain.Info`** (`lib/ash_grant/domain/info.ex`) - Domain introspection helpers

### Transformers

- **`AshGrant.Transformers.MergeDomainConfig`** - Merges domain-level resolver/scopes into resources (runs first)
- **`AshGrant.Transformers.ValidateResolverPresent`** - Validates resolver exists after domain merge
- **`AshGrant.Transformers.AddDefaultPolicies`** - Auto-generates policies when `default_policies: true`
- **`AshGrant.Transformers.AddCanPerformCalculations`** - Generates CanPerform calculations from `can_perform` entities and `can_perform_actions` option
- **`AshGrant.Transformers.AddArgumentResolvers`** - For each `resolve_argument` declaration: validates path, checks at least one scope references the arg, injects `argument :name` + `change AshGrant.Changes.ResolveArgument` on every targeted write action
- **`AshGrant.Transformers.ValidateScopeThroughs`** - Validates scope_through entities reference valid belongs_to relationships

## Permission Format

```
[!]resource:instance_id:action:scope
```

- `!` prefix = deny rule
- `instance_id` = `*` for RBAC, specific ID for instance permissions
- Deny rules always override allow rules
- `instance_key` option: changes which field instance IDs match against (default `:id`)
- `scope_through` entity: propagates parent instance permissions to child resources via FK
- `action` = exact name, `*` (any action), or a **type wildcard** matching by Ash action
  type: `@read` / `@create` / `@update` / `@destroy` / `@action`. A type wildcard never
  reads the action name. The older `read*` spelling means the same thing but is
  deprecated (removal at v1.0.0) — it looks like a prefix glob and never was one.
- Permission strings are **runtime data** from the `PermissionResolver` (roles table,
  seeds), not DSL — so there is no compile-time site to validate them. Deprecated/dead
  syntax is reported offline instead, via `AshGrant.Permission.diagnostics/1` and
  `mix ash_grant.verify`.

## Key Patterns

### Scope DSL

Scopes are defined inline with `expr()` expressions:

```elixir
ash_grant do
  scope :always, true
  scope :own, expr(author_id == ^actor(:id))
  scope :own_draft, [:own], expr(status == :draft)  # Inherits from :own
end
```

### Multi-tenancy

Use `^tenant()` in scope expressions:

```elixir
scope :same_tenant, expr(tenant_id == ^tenant())
```

## Test Structure

- **Unit tests**: `test/ash_grant/permission_test.exs`, `evaluator_test.exs`
- **Property tests**: `permission_property_test.exs`, `evaluator_property_test.exs`
- **DB integration**: `db_integration_test.exs` (requires PostgreSQL)
- **Business scenarios**: `business_scenarios_test.exs` (8 authorization patterns)
- **Support files**: `test/support/` contains test resources, domain, repo, and generators

Tests require PostgreSQL. The test alias auto-runs `ecto.create` and `ecto.migrate`.

## Dependencies

- **Runtime**: `ash ~> 3.0`, `spark ~> 2.0`
- **Test only**: `ash_postgres`, `postgrex`, `simple_sat`

## Git Workflow

All changes must go through Pull Requests (no direct push to main).

### Branch Naming Convention

| Type | Branch Name | Example |
|------|-------------|---------|
| Feature | `feat/<description>` | `feat/sat-solver-callbacks` |
| Bug Fix | `fix/<description>` | `fix/in-operator-fallback` |
| Documentation | `docs/<description>` | `docs/update-readme` |
| Refactoring | `refactor/<description>` | `refactor/evaluator-cleanup` |
| Release | `release/v<version>` | `release/v0.4.1` |

### Commit Message Convention

```
<type>: <description>

Types: feat, fix, docs, refactor, test, release
```

### Slash Commands

Use these instead of manual steps:

- **`/pr <description>`** — Full PR workflow: code verification → doc gate → branch → commit → push → create PR
- **`/release <version>`** — Full release workflow: change analysis → docs + CHANGELOG → version bump → verify → PR → merge → tag

Both commands include a **documentation gate** that checks README, CHANGELOG, @moduledoc, and CLAUDE.md before proceeding.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AshGrant is a permission-based authorization extension for Ash Framework. It provides an Apache Shiro-inspired permission system with deny-wins semantics, supporting both RBAC and resource-instance permissions.

User-facing docs: `README.md`, `guides/`, and `usage-rules.md` (the rulebook AI agents in consumer apps follow).

## Language Policy

**All repository content must be written in English**, including:
- README.md, CHANGELOG.md, and all documentation
- Code comments and docstrings (@moduledoc, @doc)
- Commit messages and PR descriptions
- CLAUDE.md instructions

## Toolchain

`.tool-versions` pins **Elixir 1.20.4 / OTP 28** (asdf). 1.20's type checker reports
dead and unreachable clauses as compiler warnings, so `mix compile --warnings-as-errors`
must pass on 1.20. Per-PR CI (`ci.yml`) runs a matrix of the 1.18.4 / OTP 27 floor and
the 1.20.4 / OTP 28 pin, both on the committed lock; format and credo run on the pin
leg only. Keep the pin leg in step with `.tool-versions`. Develop on the pin; treat
1.18.4 as the supported floor, not as the reference build.

`ci.yml` also runs an **exact Ash floor** job (`ASH_VERSION="=3.33.4"`, see
`ash_version/1` in `mix.exs`; a bare version means `~>`). Branch protection requires a
single check named `Test`, which is an aggregate job in `ci.yml`: a job is required
when it is in that job's `needs`. The floor job is not in `needs` yet (the Ash floor
still has the ETS TableManager race, fixed in Ash 3.37.1).

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
mix ash_grant.verify priv/policy_tests/           # Every .ex/.exs/.yaml/.yml test under it
mix ash_grant.verify path/to/test.yaml --verbose  # Verbose output
# verify exits 1 when a test fails, 2 when the run is incomplete (missing path,
# compile/YAML parse failure, a named path with no tests) — a skipped file is never a pass

# Check stored permission strings against the app's resources (exit 1 on any :error)
mix ash_grant.check_permissions path/to/permissions.json --otp-app my_app
```

## Architecture

Each module's `@moduledoc` is the reference. This file does not describe modules one by
one; it keeps the map below and the rules that span modules (Invariants).

- `AshGrant.Permission` parses `[!]resource:instance_id:action:scope`; `AshGrant.Evaluator`
  applies deny-wins over a permission list.
- Policy checks live in `lib/ash_grant/checks/`: `Check` (writes, true/false),
  `FilterCheck` (reads, a filter), `FieldFilterCheck` (per-record field visibility,
  generated into `field_policies`), `UngroupedFieldCheck` (`deny_fields_by_default`).
  `FieldCheck` is the legacy action-wide field check, no longer generated.
- Compile time: `lib/ash_grant/transformers/` generate policies, field policies,
  masking, `can_perform` calculations and `resolve_argument` wiring;
  `lib/ash_grant/verifiers/` run post-compile, so their errors surface as compile warnings.
- Domain inheritance is resolved at runtime by `AshGrant.Info`: the resolver falls back
  resource > domain > `config :ash_grant, resolver:`, and scopes merge resource > domain >
  `ScopeRegistry`. There is no merge transformer (removed in v0.20.0).
- Offline tooling never affects authorization: `Permission.diagnostics/1`,
  `PermissionValidation.check/2` (+ `Validations.PermissionStrings`,
  `mix ash_grant.check_permissions`), `mix ash_grant.verify`.

## Invariants

Rules that span modules, so no single file shows them. When a change creates or moves
one, update it here in the same PR.

- **Ceiling is an intersection, never a union.** Every call site that resolves
  permissions (`Check`, `FilterCheck`, `FieldFilterCheck`, `FieldCheck`, `CanPerform`,
  `ApplyMasking`, `ResolveArgument`, `Explainer`, `Introspect`, `PolicyTest.Checker`)
  evaluates the grants and the resolver's `ceiling/2` list separately and intersects the
  results, so a deny in either wins. Concatenating the two lists makes a union.
  `ceiling_property_test.exs` pins reads, `Introspect.can?/4` and the write check.
- **What a scoped instance grant reaches is decided in `AshGrant.InstanceFilter` only.**
  `FilterCheck`, `CanPerform`, `FieldFilterCheck` and `Explainer` build their filter with
  it; `Check`, `Introspect` and `PolicyTest.Checker` use its `condition/3`,
  `unconditional?/1` and `reachable?/2`. An undeclared instance scope authorizes nothing
  and logs; it never raises (#207).
- **`Evaluator.get_write_scopes/4` sees RBAC grants only** (`Permission.matches?/4` drops
  instance permissions). `Check` matches instance grants and `scope_through` parents
  itself; any passing grant authorizes (#123).
- **The builtin-scope set (`always`/`all`/`global`) lives in the checks and in
  `PermissionValidation`.** `permission_check_test.exs` pins them together: the real
  `FilterCheck`/`Check` must raise the undeclared-scope error on exactly the resources a
  static-checker scope error names, except an instance grant, whose `:undeclared_scope` is
  an `:error` that does not raise. Change both sides together.
- **`deny_fields_by_default` flips the meaning of `[]`.** `Evaluator.get_all_field_groups/5`
  returns `[]` for "unrestricted" with the flag off and for "no group" with it on, so every
  caller (`FieldCheck`, `ApplyMasking`, `Introspect`, `PolicyTest.Assertions`) must pass
  `deny_fields_by_default:` and branch on it. The flag resolves at runtime
  (`Info.deny_fields_by_default?/1`: resource > domain > `config :ash_grant` > `false`)
  because a transformer cannot read the domain. `default_field_policies` resolves at
  compile time (`Info.resolve_default_field_policies/2`: resource > `config :ash_grant` >
  `false`, no domain level); without it the flag resolves to `false`.
- **Generated field policies name ungrouped fields explicitly, never as `:*`.** Ash may
  expand `:*` to every field, and every policy on a field must pass. `AddFieldPolicies`
  adds a `:*` allow-all only for Ash's coverage check.
- **Policy-test record evaluation lives in `PolicyTest.Checker` only.** The DSL runner
  (`Assertions`) and `YamlParser` both call it; their copies drifted before (#143). It
  mirrors the runtime read union (any grant's scope, an instance ID, a `scope_through`
  parent ID) minus records an instance deny names, with IDs cast as
  `Evaluator.cast_instance_ids/2` does. A scope it cannot evaluate in memory
  (`fragment()`, `exists()`, an eval error, a non-boolean) is `{:indeterminate, reason}`
  and fails the assertion in both directions; never guess `true` or `false`.
- **Signals never change an authorization result.** `IndeterminateMatch`,
  `PermissionValidation`'s `field_group_permissions` mode and `diagnostics/1` only report.
  `IndeterminateMatch` must stay sound: it recomputes a result with the skipped type
  wildcards forced to match and signals only when the answer differs, because a false
  positive breaks `:strict`.
- **Transformer order needs explicit edges.** A transformer that reads actions declares
  `after?(Ash.Resource.Transformers.SetPrimaryActions)`; without it Spark's tie-break
  shifts between Ash versions and `AddArgumentResolvers` once ran before `defaults [...]`
  actions existed. Two transformers that both return `after?(_) -> true` have no edge
  between them (see `AddCanPerformCalculations`).

## Permission Format

```
[!]resource:instance_id:action:scope
```

- `!` prefix = deny rule
- `instance_id` = `*` for RBAC, specific ID for instance permissions
- Deny rules always override allow rules
- `instance_key` option: changes which field instance IDs match against (default: the primary key)
- `scope_through` entity: propagates parent instance permissions to child resources via FK
- `action` = exact name, `*` (any action), or a **type wildcard** matching by Ash action
  type: `@read` / `@create` / `@update` / `@destroy` / `@action`. A type wildcard never
  reads the action name. The older `read*` spelling means the same thing but is
  deprecated (removal at v1.0.0) — it looks like a prefix glob and never was one.
  A type wildcard can only be evaluated when an `action_type` is supplied; calling
  `Evaluator` directly without one silently skips it and may return a wrong answer
  (`AshGrant.IndeterminateMatch` signals this — see #126, layer 2). Framework checks
  always pass the type; prefer `Introspect.can?/4` (takes the resource module) in your
  own code.
- Permission strings are **runtime data** from the `PermissionResolver` (roles table,
  seeds), not DSL — so there is no compile-time site to validate them. Deprecated/dead
  syntax is reported offline instead, via `AshGrant.Permission.diagnostics/1` and
  `mix ash_grant.verify`. Whether a string names things that *exist* (resource, action,
  scope, field group) is checked the same way: `AshGrant.PermissionValidation.check/2`,
  `AshGrant.Validations.PermissionStrings`, `mix ash_grant.check_permissions` (#162).

## Test Structure

- **Unit tests**: `test/ash_grant/permission_test.exs`, `evaluator_test.exs`
- **Property tests**: `permission_property_test.exs`, `evaluator_property_test.exs`, plus
  the pins named under Invariants
- **DB integration**: `db_integration_test.exs` (requires PostgreSQL)
- **Business scenarios**: `business_scenarios_test.exs`
- **Support files**: `test/support/` contains test resources, domain, repo, and generators

Tests require PostgreSQL. The test alias auto-runs `ecto.create` and `ecto.migrate`.
CI compiles with `MIX_ENV=test --warnings-as-errors`, so `test/support` must compile
without warnings: a resource that uses a deprecated DSL option (a compile-time warning)
belongs inline in the `.exs` test that needs it.

## Dependencies

- **Runtime**: `ash ~> 3.33 and >= 3.33.4`, `spark ~> 2.0` (the Ash floor is a security floor — everything below 3.33.4 has published advisories; see the v0.21.0 CHANGELOG entry for the precedent. 3.33.4 is the first release with the fix for CVE-2026-86338, which the field policies AshGrant generates were exposed to). `mix hex.audit` is the only command that reports advisories in the committed lock — `mix deps.get` stays silent
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

Both commands include a **documentation gate** that checks README, CHANGELOG, @moduledoc, and CLAUDE.md's Invariants before proceeding.

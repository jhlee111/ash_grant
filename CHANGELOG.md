# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **`global` is now a universal scope on the write path too** ([#139](https://github.com/jhlee111/ash_grant/issues/139)). It was honored on reads but crashed `AshGrant.Check` on writes. The universal-scope predicate is centralized in `AshGrant.Scope.universal?/1`, and the static checker now accepts `global` everywhere. Declaring a scope with a reserved universal name (`always`/`all`/`global`) and a non-`true` filter now emits a compile warning, since the checks short-circuit on the name and would silently ignore the filter.

## [0.22.0] - 2026-09-19

### Added

- **A static checker for stored permission strings** ([#162](https://github.com/jhlee111/ash_grant/issues/162)). Permission strings are runtime data — a roles table edited from an admin UI, a seed file, a migration — so the compiler never sees them, and until now nothing checked that a stored string names things that exist. A wrong segment failed in four different ways, only one of them loud:

  | Wrong segment | What happens at runtime |
  |---|---|
  | resource | The grant matches nothing. Silently inert. |
  | action | The grant matches nothing. Silently inert. |
  | scope | **The check raises**, on whatever request first reaches that resource. |
  | field group | The grant still matches, but makes no field visible. Silently forbidden. |

  A rename in code — an action, a scope, a field group — orphaned every stored string that used the old name, and nothing reported it before a check tripped over it.

  `AshGrant.PermissionValidation` grows from one request-time rule into a checker you run wherever your strings live:

  - **`check/2` and `check_all/2`** compare a permission against the application's resources (`resources:` or `otp_app:`) and return issues — `%{code, severity, segment, message, permission, resources}` — with `[]` meaning the string checks out. `errors?/1` tells errors from warnings. Codes: `:parse_error`, `:unknown_resource`, `:unknown_action`, `:undeclared_scope`, `:scope_missing_on`, `:unverifiable_scope`, `:unknown_field_group`, `:field_group_missing_on`, `:deny_with_field_group` (the [#117](https://github.com/jhlee111/ash_grant/issues/117) rule, as a code), plus the three from `AshGrant.Permission.diagnostics/1`. Messages suggest the nearest declared name for a typo.
  - **`AshGrant.Validations.PermissionStrings`** is an Ash validation for the attribute that stores grants: `validate {AshGrant.Validations.PermissionStrings, attribute: :permissions}`. One field error per bad string, naming the string. It only checks the attribute when the action changes it, so a string that went stale after a rename never blocks an unrelated edit to the same record.
  - **`mix ash_grant.check_permissions FILE`** is the CI and deploy-step form: a JSON array (or an object of labelled arrays), a newline list, or `-` for standard input; `--otp-app`; `--format json`. It exits `1` exactly when an `:error` is present, `0` for warnings only, and `2` for a usage error — including "no AshGrant resources found", so a wrong `--otp-app` says so instead of reporting every string as an unknown resource.

  **The static check and the runtime agree, and a property test holds them to it.** The checker reads the same metadata the checks read and matches actions with `AshGrant.Permission.matches_action?/3`. The test runs the real `AshGrant.FilterCheck` and `AshGrant.Check` over generated strings and requires the undeclared-scope error on *exactly* the resources a scope error names — no missed raise, and no false positive. That requirement is what decided the rules:

  - A scope or field group is owed only by **the resources the grant applies to** — those where its action segment matches an action. `*:*:approve:own_unit` needs `own_unit` on every resource with an `approve` action, not on every resource in the application. The ones lacking it are listed by name (`:scope_missing_on`).
  - `always` and `all` need no declaration. **`global` is accepted by name on the read path only** — `AshGrant.Check` raises on it ([#139](https://github.com/jhlee111/ash_grant/issues/139)) — so an undeclared `global` is reported when the grant can reach a write or generic action.
  - Names that a policy overrides to are valid: `AshGrant.check(action: "publish")` and `filter_check(resource: "blog")` are read out of each resource's policies and `CanPerform` calculations.
  - An **instance** permission may name an action of a resource that `scope_through`s the one it names: the checks match the parent's instance permissions against the child's action.
  - An undeclared scope on a **deny** or an **instance** permission is a warning, not an error. The framework never resolves those scopes, so they cannot raise.
  - A configured `scope_resolver` turns an unknown scope into `:unverifiable_scope`, a warning: the resolver may know it, and that cannot be checked ahead of time.
  - Under a `*` or shared resource name, a resource declaring no field groups at all is not expected to declare the one in the 5th segment.

  None of this changes an authorization outcome. The new surface is listed in the [Public API Contract](guides/public-api-contract.md) as **Provisional**; see [Checking Stored Permission Strings](guides/permissions.md#checking-stored-permission-strings) for the guide.

### Changed

- **The minimum supported Ash is now `~> 3.33 and >= 3.33.4` (was `~> 3.33`)**, for [CVE-2026-86338](https://osv.dev/vulnerability/EEF-CVE-2026-86338) / [GHSA-7qr8-wrvq-566q](https://github.com/ash-project/ash/security/advisories/GHSA-7qr8-wrvq-566q) (MEDIUM, published 2026-09-16): Ash field policies did not replace forbidden calculations and aggregates with `nil` inside a filter, so an actor could learn a hidden value from whether rows came back.

  **AshGrant was exposed.** A `field_group` may list public calculations and aggregates, so a generated field policy can be the only thing hiding a computed value. On Ash 3.33.3, an actor without the group could run `filter(secret_calc == "x")` and read the answer off the result. The bug and the fix are entirely in Ash's authorizer — no AshGrant source changed — but the release now proves the fix in AshGrant's own terms: `field_group_filter_oracle_test.exs` covers an attribute, a calculation and a `count` aggregate in one group, and fails 3 of its 9 cases on Ash 3.33.3. That includes the per-record case, where `AshGrant.FieldFilterCheck` makes visibility a per-row predicate and the `nil` replacement has to be per row as well.

  v0.21.0 established that the Ash requirement is a security floor that must not admit a version with a published advisory. 3.33.0–3.33.3 all carry this one, so the floor moves. Unlike v0.21.0 this stays within one minor: a consumer already on Ash 3.33.x only needs `mix deps.update ash`. **Consumers staying on AshGrant 0.21.x should run that too** — those releases still declare `~> 3.33`, and only your own lock decides which patch you run. `mix.lock` moves to Ash 3.33.6, and `mix hex.audit` reports nothing again.

### Fixed

- **A race in the test suite that could fail CI on an unrelated change.** Two test modules captured `:stderr` while running `async: true`. Capturing stderr swaps the global `:standard_error` device, so another test writing to stderr as a capture started or ended crashed with `:terminated`. Both modules now run synchronously. Test-only; nothing in the package changes.

## [0.21.1] - 2026-09-12

### Fixed

- **`mix ash_grant.explain` reported only the first matching allow scope** ([#151](https://github.com/jhlee111/ash_grant/issues/151)). `Explainer.resolve_explain_scope_filter/4` matched `[first | _]` over the matching allows and resolved that one scope, while the read path ORs every matching scope. An actor holding two grants on the same resource and action was shown a filter narrower than the one actually applied — and *which* of the two got reported depended on the order the `PermissionResolver` returned them in.

  This was sharpest right after the [#149](https://github.com/jhlee111/ash_grant/issues/149) fix: a scope declared `scope(:x, true)` alongside a narrowing scope now grants every row, but the explainer would still print the narrowing filter. The diagnostic contradicted the behaviour it exists to describe.

  The explainer now mirrors `FilterCheck.build_combined_filter/3` exactly, `true`-absorption included.

- **Two `@moduledoc`s still described the pre-#149 model.** `AshGrant.FilterCheck` documented `true` as meaning "actor has an `always`/`all`/`global` scope", and `AshGrant.Calculation.CanPerform` listed only the by-name path. Since v0.20.1 the value decides and the name is a fast path; both now say so. These ship in the package, so the published docs asserted the older rule.

## [0.21.0] - 2026-09-12

### Changed

- **The minimum supported Ash is now `~> 3.33` (was `~> 3.19`).** Every Ash release below 3.33 carries published security advisories — `mix hex.audit` reports 19 against 3.24.1, the version this project had locked, including one HIGH. There is no version below 3.33 to fall back to, so the floor moves rather than being held for compatibility. `mix.lock` was regenerated at the same time; `mix hex.audit` now reports no advisories at all (`ash_postgres` 2.9.0 → 2.13.1, `ash_sql` 0.6.0 → 0.7.3, `postgrex` 0.22.0 → 0.22.4, plus transitive `mint`, `req`, `hpax`, `decimal`, `ymlr`).

  Consumers pinned below Ash 3.33 must upgrade Ash to take this release. AshGrant's own code needed no change for it: the suite passes unmodified against Ash 3.33.3 / AshPostgres 2.13.1 / Spark 2.7.2.

### Removed

- **Four unreachable clauses, one of which is observable.** Elixir 1.20's type checker proved them dead; each was already unreachable and only started being reported. `AshGrant.Check.simplify_exists_for_eval/1` (`true`/`false`) and `AshGrant.FieldCheck.field_group_grants_access?/3` (`[]`) are guarded by their callers and cannot be reached at all.

  The observable one is the catch-all clause of `Mix.Tasks.AshGrant.Explain.format_error/1`. `AshGrant.Introspect.explain_by_identifier/1`'s `@spec` closes the error domain to `:unknown_resource | :actor_not_found | :actor_loader_not_implemented`, each of which has its own clause — but if a value outside that `@spec` ever reaches the task, `mix ash_grant.explain` now raises a `FunctionClauseError` instead of printing `error: <inspected>`. The `@spec` is treated as the contract.

### Fixed

- **The weekly `Compatibility` workflow, failing on `main` since at least 2026-07-20.** Both of its jobs were broken, for unrelated reasons:

  - *Latest Deps* failed at compile. Newer Ash requires `config :ash, :default_string_length_count` to be set and raises a `Spark.Error.DslError` when it is not; this project never set it. Now set to `:codepoints` in `config/config.exs`, which counts the way SQL data layers do, so `max_length` means the same thing in validation and in the database.
  - *Ash Floor* failed before it started. The job resolved the floor version against the committed `mix.lock`, where `ash_postgres` required a much newer Ash than the floor allowed — an unsatisfiable set, so `mix deps.get` exited on a Hex resolution error. The job now unlocks first, as the *Latest Deps* job already did.

## [0.20.1] - 2026-09-12

### Fixed

- **A scope whose expression resolves to `true` was dropped from the read-side `OR` union unless the scope happened to be named `always`, `all` or `global`** ([#149](https://github.com/jhlee111/ash_grant/issues/149)). `AshGrant.FilterCheck`, `AshGrant.FieldFilterCheck` and `AshGrant.Calculation.CanPerform` each rejected `true` from the resolved filter list before combining what was left, so `true OR narrowing` collapsed to `narrowing` — the opposite of what `OR` means.

  An actor holding both `post:*:read:everything` (declared `scope :everything, true`) and `post:*:read:mine` therefore read only their own rows: a filter narrower than either grant alone. The three sites now let a resolved `true` absorb the union.

  The bug failed closed, so it surfaced as missing rows, a field group hidden on rows that should show it, or a `can_*?` calculation answering `false` — never as a leak. Write actions were already correct: `AshGrant.Check` OR-composes with `Enum.any?/2`, where a scope resolving to `true` passes ([#123](https://github.com/jhlee111/ash_grant/issues/123)). Fixing `CanPerform` therefore also closes an asymmetry where the UI said `false` for records the write path authorizes.

  The `always`/`all`/`global` name check is unchanged and still short-circuits before any scope is resolved. It is now only a fast path: **what makes a `true` scope work is its value, not its name.** Scopes named by the [naming convention](guides/scope-naming-convention.md) keep behaving exactly as before.

  The three sites that combine with `AND`, where dropping `true` is correct, are untouched: scope inheritance in `AshGrant.Info` and `AddArgumentResolvers.combine/2`.

## [0.20.0] - 2026-08-02

Ports the compile-cycle fix from the [team-alembic fork](https://github.com/team-alembic/ash_grant/pull/4), authored by Barnabas Jovanovics and Conor Sinclair. The `:always` → `:all` scope renaming that fork also carries is **not** included — this project's `:always` convention and the `@read` type-wildcard spelling are unchanged.

### Breaking Changes

- **A missing resolver no longer fails the build.** `AshGrant.Transformers.ValidateResolverPresent` and `AshGrant.Transformers.ValidateScopes` became `AshGrant.Verifiers.ValidateResolverPresent` and `AshGrant.Verifiers.ValidateScopes`. Verifiers run post-compile, which is what lets them reach into the domain without closing a compile cycle — but Spark surfaces verifier errors as compile **warnings**, not errors. So a resource with no resolver (on itself or its domain) now *compiles* — emitting a `No resolver configured` warning — and instead raises the first time authorization runs against it. `AshGrant.Check` raises `ArgumentError`, which Ash wraps, so what a caller rescues is `Ash.Error.Unknown` carrying the message `no resolver configured for …`.

  If you relied on the compile error as your gate, make the warning one: build with `--warnings-as-errors`, or fail CI on the verifier's output. A misconfiguration that used to stop the build now reaches runtime.

  The namespace move is itself breaking: anything naming `AshGrant.Transformers.ValidateResolverPresent` or `AshGrant.Transformers.ValidateScopes` directly must be updated.

- **`AshGrant.Transformers.MergeDomainConfig` is removed.** Domain-level `ash_grant` config is no longer folded into the resource's DSL state at compile time. It is resolved at runtime instead: `AshGrant.Info.resolver/1` falls back to the domain when the resource declares none, and `AshGrant.Info.scopes/1` merges resource and domain scopes with resource precedence.

  Configuration outcomes are unchanged. What changes is where the merged value lives: code that read domain-inherited config straight out of Spark DSL state — `Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :resolver)`, `get_entities(resource, [:ash_grant])` — now sees only what the resource itself declares. Read through `AshGrant.Info` instead.

### Fixed

- **Compile deadlock when a domain combined `AshGrant.Domain` with a `code_interface` block.** A resource using `AshGrant`, on a domain that both used `AshGrant.Domain` and declared `code_interface do define … end`, deadlocked: the resource's `MergeDomainConfig` transformer forced the domain to compile so it could read the domain's `ash_grant` DSL, while the domain's `code_interface` transformer was waiting on the resource. `define` calls `Ash.CodeInterface.require_action/2` at compile time, so the wait is mutual and the compiler reports `deadlocked waiting on module …` for every resource in the cycle.

  The cycle did not need the resource carrying the `define` to be AshGrant-extended itself — a domain-level `define` on any resource that compile-depends on an extended sibling was enough to close it, which is why the failure often surfaced far from the resource that was actually configured.

  Moving the merge to runtime and the validations to verifiers removes both compile-time edges. `test/ash_grant/code_interface_cycle_test.exs` pins the combination.

## [0.19.0] - 2026-07-17

### Added

- **Indeterminate type-wildcard evaluation is now signaled** (#126). A type wildcard matches on the Ash action **type**, so an `Evaluator` entry point called without an `action_type` cannot evaluate it. Previously it silently skipped the wildcard and fabricated an answer — a `false` that means "could not tell", indistinguishable from a real deny, so the same actor and grant got opposite answers from the two APIs (`Introspect.can?(Document, :read, actor)` → allow; `Evaluator.has_access?(perms, "document", "read")` → `false`), which in practice forced defensive `@read` + literal `read` grant pairs. In the deny direction the skip is fail-open: a skipped `!…:@read:…` deny leaves `true` standing. The new `AshGrant.IndeterminateMatch` recomputes the result with the skipped RBAC type wildcards forced to match and signals only if that changes the answer — sound by construction, so defensive wildcard+literal pairs, wildcards that contribute nothing, and queries already settled by a concrete deny stay silent. Severity is configurable, mirroring `field_group_permissions`:

      config :ash_grant, indeterminate_type_wildcard: :warn   # :off | :warn (default) | :strict

  `:warn` logs, `:strict` raises, `:off` disables — and **authorization outcomes never change** in any mode. All eight nil-defaulting entry points are guarded (`has_access?`, `get_scope`, `get_all_scopes`, `get_write_scopes`, `get_field_group`, `get_all_field_groups`, `find_matching`, `field_group_grants`). Framework-generated policies always pass the action type and are unaffected; the signal concerns direct `Evaluator` calls — in application code, prefer `AshGrant.Introspect.can?/4`, which takes the resource module and resolves the type itself. `get_matching_instance_ids/4` is deliberately unguarded; the pre-existing instance-path inconsistency that decision surfaced is tracked in #131.

### Changed

- Type-wildcard documentation and examples now lead with the `@read` spelling (`AshGrant.Permission`, the `AshGrant.Evaluator` moduledoc, `usage-rules.md`, `guides/permissions.md`), with `read*` shown only as the deprecated equivalent.

## [0.18.0] - 2026-07-17

### Added

- **Explicit action-type wildcard: `@read`** (#126). Type wildcards can now be spelled `@read`, `@create`, `@update`, `@destroy`, `@action` — e.g. `"blog:*:@read:always"`. Semantics are identical to the existing `read*` form (match on the Ash action **type**, never on the action name), but the notation can no longer be misread as a prefix glob. Both spellings work; `@` cannot collide with an action name, since Elixir action atoms never start with it.

- **`AshGrant.Permission.diagnostics/1`** (#126) reports deprecated or dead grant syntax for a permission string or struct, returning `%{code:, permission:, message:, suggestion:}` maps. Three codes:
  - `:deprecated_type_wildcard` — the `read*` spelling; suggests the `@read` equivalent
  - `:dead_instance_type_wildcard` — a type wildcard on an instance permission. Instance matching has no action type available, so the grant **never matches anything** (`"blog:post_abc:read*:"` is dead). Previously silent and undocumented.
  - `:unknown_action_type` — a type wildcard naming something that is not an Ash action type. `delete*` is the common case: Ash calls that type `:destroy`, so `"blog:*:delete*:always"` silently never matches. Suggests `@destroy`.

  Permission strings are runtime data that AshGrant cannot reach, so this is exposed as a function to run over your own store:

      MyApp.Role
      |> MyApp.Repo.all()
      |> Enum.flat_map(& &1.permissions)
      |> Enum.flat_map(&AshGrant.Permission.diagnostics/1)

  Authorization behavior is unchanged — a flagged permission still evaluates exactly as it did before.

- **`mix ash_grant.verify` reports permission syntax warnings** (#126) by resolving each policy test actor's grants and running `diagnostics/1` over them. This only covers grants the declared test actors hold, so a clean run is **not** proof that your permission store is clean; YAML tests carry their permissions inline and are not scanned. Warnings never affect the exit code.

### Deprecated

- **The `read*` spelling of type wildcards** (#126), in favor of `@read`. Removal planned for v1.0.0. `read*` still works and its behavior is unchanged. Unlike the `[:*]` → `:all` and scope `write:` deprecations — which were DSL options the compiler could see — permission strings are runtime data from the `PermissionResolver` (your roles table, your seeds), so **there is no compile-time warning** and migrating means updating stored data rather than editing source. Run `mix ash_grant.verify`, or `AshGrant.Permission.diagnostics/1` over your own store, to find grants that need it.

### Fixed

- **`matches_action?/2`'s docstring documented the opposite of what the code does** (#126). It claimed "prefix matching with `prefix*`" while `matches_action?/3`, twenty lines below, correctly documented type matching — and the `/2` doctest already refuted its own prose, so the suite stayed green while the documentation misled. Corrected, along with: `matches?/4` (whose "will **also** match" implied name-prefix matching happened too), `matches?/3` (its `false` is caused by the absent `action_type`, not by a failed name comparison), the moduledoc format table, and `usage-rules.md`, whose examples used only `read`-prefixed action names and so taught the glob model by example.

- **`matches_instance?/3` silently never matches type wildcards, previously undocumented** (#126). Instance matching passes no action type, so a type wildcard on an instance permission is dead. Now documented, doctested, and reported by `diagnostics/1`.

- **Three places claimed type wildcards do not apply to generic actions** (#126) — `guides/permissions.md`, `guides/checks-and-policies.md`, and `AshGrant.Check`'s `@moduledoc`. They do apply: `"service:*:@action:always"` grants **every** generic action on the resource, including ones added later, so the grant that permits `:ping` also permits `:process_refund`. All three now document the real behavior and warn against relying on it; for generic actions, prefer exact action names. Whether to block this is tracked in #127.

## [0.17.0] - 2026-07-06

### Fixed

- **Write actions resolved only ONE grant's scope — adding a narrow grant to a role holding a blanket grant revoked the action** (#123). `AshGrant.Check` used `Evaluator.get_scope/4`, which returns the scope of whichever matching allow permission appears *first* in the resolver's list, ignoring every other grant. An actor holding `["schedule:*:cancel:online_content", "schedule:*:*:always"]` was forbidden from canceling a regular class — the additive grant acted as a revocation — and the outcome depended on permission-list order (i.e. DB row order). Write and generic actions now OR-compose **all** matching grants' scopes via the new `AshGrant.Evaluator.get_write_scopes/4` and authorize when **any** scope passes: the union semantics `FilterCheck` (read) and `CanPerform` (UI) have always applied, and the write-path analogue of #116's group-less collapse — adding an allow grant must never subtract access. Deny rules still win over the whole union, a scope-less grant (legacy 2-part format) still short-circuits to unrestricted, and each scope keeps its own evaluation strategy (in-memory or DB-query fallback). The same union now flows through the tooling: `Introspect.can?/4` allow-details carry `scopes:` (all matching grants' scopes) next to the backward-compatible `scope:` (first match), and `AshGrant.PolicyTest` record assertions (`assert_can/3` / `assert_cannot/3`) evaluate the union, so policy tests agree with runtime.

### Changed

- **`write: false` is per-grant, not per-actor** (consequence of #123). A scope with `write: false` prevents grants carrying *that scope* from authorizing a write; the actor's other matching grants are still evaluated. Previously it could hard-block the whole action whenever it happened to be the first matching grant. To hard-block an action regardless of an actor's other grants, use a `!` deny permission.

## [0.16.0] - 2026-06-24

### Added

- **Per-record field visibility** (#117 phase ②). Field-group access can now vary **per record** instead of per action. An actor whose row access is broader than their field-group access sees a field on some records and `%Ash.ForbiddenField{}` on others, in the same result set — the pattern the action-wide model could not express:

  ```elixir
  # public on every readable row, sensitive only on rows the actor owns
  ["employee:*:read:always:public", "employee:*:read:own:sensitive"]

  # sensitive only on a specific instance
  ["employee:*:read:always:public", "employee:emp_123:read::sensitive"]
  ```

  `default_field_policies: true` now generates field policies backed by the new `AshGrant.FieldFilterCheck` (an `Ash.Policy.FilterCheck`) instead of the action-wide `AshGrant.FieldCheck` (a `SimpleCheck`). For each field group it builds a per-row predicate from the actor's reaching grants — the scope expression for RBAC grants, `id in [...]` for instance grants — OR-combined, with downward inheritance. A new `AshGrant.Evaluator.field_group_grants/5` enumerates those grants (including instance permissions, which `get_all_field_groups/4` discards).

  **Backward-compatible**: a trivial-scope grant (`resource:*:read:always:group`) resolves to `true` → visible on all rows, identical to the previous action-wide behavior; masking and the #116 group-less collapse are unchanged.

### Fixed

- **Ungrouped public fields were forbidden for every actor** under `default_field_policies: true`. A public attribute in no field group (e.g. a timestamp or foreign key) became `%Ash.ForbiddenField{}` for everyone, because the generated catch-all `field_policy :*` was keyed literally in the rebuilt field-policy cache while Ash looks fields up concretely. The cache now expands `:*` into the concrete ungrouped fields, so they stay visible (matching the catch-all's documented intent).

## [0.15.0] - 2026-06-24

### Added

- **`field_group_permissions` option + validation for invalid field-group denies** (#117). A permission that is a deny (`!` prefix) **and** carries a `field_group` (5th part) — e.g. `"!employee:*:read:always:sensitive"` — is invalid: field-group access is positive-only, so column restrictions belong in the resource's `field_group` definition (`inherits`/`except`/`mask`), not in a deny rule. Such a deny currently over-denies the *entire* action (fail-closed) rather than the named group. The new `field_group_permissions` option on the `ash_grant` block controls how this is signaled, without changing the authorization outcome:
  - `:off` — silent (legacy behavior)
  - `:warn` — over-denial plus a `Logger.warning` (**default**)
  - `:strict` — raise `AshGrant.PermissionValidation.InvalidPermissionError`

  A global default may be set with `config :ash_grant, field_group_permissions: :strict`. Introduced `AshGrant.PermissionValidation` and `AshGrant.Info.field_group_permissions/1`; `AshGrant.Evaluator.normalize_permissions/1` is now public.

## [0.14.2] - 2026-06-23

### Fixed

- **Group-less (4-part) read grant was silently narrowed by a field-group grant** (#116). `AshGrant.Evaluator.get_all_field_groups/4` dropped group-less allow grants via `Enum.reject(&is_nil/1)`, so a broad "all fields" grant (`employee:*:read:always`) combined with a narrow field-group grant (`employee:*:read:always:sensitive`) downgraded the actor to **only** the narrow group's fields — every other field became `%Ash.ForbiddenField{}`, and via `AshGrant.Preparations.ApplyMasking` fields that should have been raw started being masked. Adding an allow grant must never subtract access. The union now collapses to `[]` (the "unrestricted" signal every consumer already understands) whenever any matching allow grant is group-less, so a broader group-less grant is never narrowed by a more specific field-group grant. A group-less grant scoped to a *different* action is correctly excluded and does not over-grant.

## [0.14.1] - 2026-04-13

Two fixes that make `resolve_argument` (introduced in 0.14.0) actually
usable outside `AshGrant.PolicyTest` — both bugs rendered the DSL sugar
a silent no-op in production. Also bumps the hard Ash floor to 3.19 for
compatibility-CI parity.

### Fixed

- **`resolve_argument` was a silent no-op for non-plain-map actors** (#101). The `needs_resolution?/3` optimization read permissions straight off `actor.permissions` and returned `[]` for any actor that was not a literal map with a `:permissions` key. Real Ash resource structs carry no such field — permissions come from the configured `PermissionResolver` — so the change never ran in production, the argument stayed `nil`, and argument-based scopes always denied. `AshGrant.Changes.ResolveArgument` now routes through the resource's configured resolver (same source as `AshGrant.Check`/`FilterCheck`) and conservatively resolves the argument when the resolver is absent or raises, rather than skipping.
- **`resolve_argument` silently failed on CREATE for attribute-multitenant targets** (#99). `AshGrant.Changes.ResolveArgument` did not forward the changeset's tenant to `Ash.get!`/`Ash.load!`, so whenever any hop in `from_path` pointed to a resource with `multitenancy strategy: :attribute`, the fetch raised, the rescue returned `nil`, and the argument-based scope evaluated to `false` — denying the action. The change now passes `tenant: changeset.tenant` to both the create-path `safe_get/3` and the update/destroy-path `safe_load/3`.

### Changed

- **Ash floor bumped from `~> 3.7` to `~> 3.19`** (#98). Aligns the declared minimum with the version the compatibility CI matrix already exercises.

### Documentation

- ExDoc now surfaces the `scope-naming-convention.md` and `argument-based-scope.md` guides in its extras list (previously authored but unlinked in `mix.exs`).
- `AshGrant.ArgumentAnalyzer` `@moduledoc` no longer references a removed helper on `AshGrant.Check`.

## [0.14.0] - 2026-04-13

This release is centred on a new **argument-based scope pattern** for
multi-hop authorization, fixes a related security bypass in composite
scope routing, and begins deprecating the `write:` scope option in favour
of the new pattern.

### Added

- **`resolve_argument` DSL entity** for argument-based scopes (#90). Declare a scope that compares an action argument (`^arg(:name)`) to actor attributes, and let the resource populate the argument from its own relationships:

  ```elixir
  ash_grant do
    scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
    resolve_argument :center_id, from_path: [:order, :center_id]
  end
  ```

  The transformer validates the path, detects dead declarations, and auto-injects an argument + a lazy change on every write action. The change only performs the DB load when an in-play permission uses a scope that actually references the argument — direct-attribute scopes pay zero cost. Multi-hop paths (e.g., `[:order, :customer, :organization_id]`) are supported. See the new [Argument-Based Scope guide](guides/argument-based-scope.md).
- **`^arg(:name)` templates in scope expressions** now resolve correctly at strict-check time (#88). Previously `AshGrant.Check` never forwarded `changeset.arguments` to `Ash.Expr.fill_template`, so any scope using `^arg(...)` crashed with `BadMapError` before this release.
- **Explain surface for `resolve_argument`** (#93). `AshGrant.Explanation` gains a `:resolve_arguments` field populated by `Explainer.explain/4`, and `Explanation.to_string/2` renders a new "Argument Resolution" section showing each declared resolver, its path, and which scopes trigger it.
- **PolicyTest support for action arguments** (#93). `assert_can`/`assert_cannot` accept a keyword-list third argument — `[record: ..., arguments: ...]` — and `YamlParser` parses an `arguments:` field on each test. `DslGenerator` emits the keyword-list form when converting YAML→DSL.

### Fixed

- **Composite scope on create security bypass** (#87, closes #83). `should_use_db_query?/3` now inspects the resolved filter (with inheritance applied) instead of the child scope's raw `scope_def.filter`. Composite scopes inheriting a relational parent (`exists()` or dot-path) no longer skip the DB query fallback on create actions. Before this fix, `:at_own_unit_and_small` (inheriting a relational `:at_own_unit` parent) could silently allow unauthorized creates when the parent's `exists()` condition evaluated truthy against a virtual record.
- **Detector coverage** for function-wrapped relational references and lists (#87). `contains_relationship_reference?/1` now descends into `%{__function__?: true, arguments: ...}` structs, list RHS of `in` operators, and handles `nil` explicitly.

### Deprecated

- **`write:` option on `scope`** (#91). The option was introduced as an escape hatch for relational scopes that couldn't be evaluated in memory on writes. With `resolve_argument` now providing a first-class way to express multi-hop authorization via in-memory-evaluable scopes, `write:` is redundant for the common case. Using it still works but emits a compile-time deprecation warning pointing at the replacement pattern. A regression test (#92) asserts the warning emits with the correct message.

### Changed

- **Scope naming**: the unrestricted scope is renamed from `:all` to `:always` across the codebase, guides, and test fixtures (#84). `"all"` is still accepted as a boolean-true scope for backward compatibility; new code should use `:always`. A [Scope Naming Convention guide](guides/scope-naming-convention.md) documents the "sentence test" that motivated the rename.

### Documentation

- New [Argument-Based Scope guide](guides/argument-based-scope.md) with full Refund → Order → center_id example, hand-rolled "under the hood" section, safety analysis, and gotchas (#89).
- Cross-links from `authorization-patterns.md`, `checks-and-policies.md`, `policy-testing.md`, `scope-naming-convention.md`, `debugging-and-introspection.md`, `scopes.md`, `getting-started.md` (#94).
- `usage-rules.md` (the AI-agent-facing rulebook) rewritten to recommend `resolve_argument`, flag `write:` as deprecated, and document the new DSL entity (#95).
- `/pr` and `/release` skill doc gates extended to check `usage-rules.md` and `guides/*.md` — structural fix so these files aren't silently missed in future PRs (#95).
- New tip in `guides/scopes.md` preferring direct FK column (`is_nil(team_id)`) over relationship traversal (`is_nil(team.id)`) when the check is really about the FK itself (#96).

### Follow-up / related

- [#86](https://github.com/jhlee111/ash_grant/issues/86) (DB-query fallback limitations on function-wrapped relational refs during create) was closed as "not planned" — the argument-based pattern covers the motivating cases cleanly, and the fallback path is no longer the recommended route for authorization involving relationships.

## [0.13.5] - 2026-04-08

### Changed

- **Remove noisy `:all`/`:always` scope warning**: The compile-time warning from `ValidateScopes` that fired for every resource without a universal scope has been removed. This was a best-practice hint rather than a real validation, and produced excessive noise in projects with many resources — especially with `--warnings-as-errors`. (#81)

## [0.13.4] - 2026-04-06

### Fixed

- **Generic action authorization**: `AshGrant.Check` now correctly extracts tenant from `action_input` for generic actions (type `:action`). Previously, `get_tenant/1` only handled `query` and `changeset`, causing tenant-aware resolvers to return empty permissions for generic actions. The same fix is applied to `FilterCheck` and `FieldCheck`. (#76)
- **`default_policies` now covers generic actions**: `AddDefaultPolicies` transformer generates a policy for `action_type(:action)` using `AshGrant.Check`. Previously, resources with `default_policies true` and generic actions had no matching policy, resulting in forbidden. (#76)
- **Write scope evaluation**: Use `fill_template` and pass `resource:` option to `Ash.Expr.eval` for correct template resolution and attribute hydration in write scope checks. (#75)

## [0.13.2] - 2026-03-29

### Changed

- **Action type wildcard (`read*`) no longer matches by string prefix.** Previously, `read*` matched both actions starting with "read" (e.g., `read_all`) and actions with `:read` action type (e.g., `list`). Now `read*` matches **only by action type** — use `read` (exact) for the action named "read". This prevents false matches where an action named `read_something` could be a non-read type. (#72)

## [0.13.1] - 2026-03-29

### Added

- **Authorization Patterns guide**: New ExDoc guide covering RBAC, ABAC, ReBAC, and additional patterns (deny-wins, multi-tenancy, field-level access, domain inheritance, CanPerform). Includes practical scope DSL examples for each pattern and a comparison table. (#70)
- **Usage rules**: Document `instance_key` and `scope_through` in policy test fixtures. (#69)

## [0.13.0] - 2026-03-24

### Added

- **`instance_key` DSL option**: Match instance permission IDs against a field other than `:id`. For example, `instance_key :feed_id` makes `"feed:feed_abc:read:"` generate `WHERE feed_id IN ('feed_abc')` instead of `WHERE id IN ('feed_abc')`. Works with FilterCheck, Check, and CanPerform. (#62)
- **`scope_through` entity**: Propagate parent resource instance permissions to child resources via `belongs_to` relationships. When a user has `"feed:feed_abc:read:"`, adding `scope_through :feed` to the child resource grants access to all child records where `feed_id == "feed_abc"`. Supports action filtering with `actions:` option. (#62)
- **`ValidateScopeThroughs` transformer**: Compile-time validation that `scope_through` references valid `belongs_to` relationships.

### Changed

- **Documentation refactored into ExDoc guides**: README trimmed from 1,687 to 166 lines. Content split into 7 focused guides (Getting Started, Permissions, Scopes, Field-Level Permissions, Checks & Policies, Debugging & Introspection, Policy Testing) with ExDoc sidebar grouping under "Guides". (#65)
- **Issue #65 documentation improvements**: Action wildcard type clarification (`read*` matches action type, not string prefix), instance permission boundary note, per-action `default_policies` subsection, RBAC + instance OR combination example, relational scopes tip in Getting Started.

## [0.12.0] - 2026-03-16

### Added

- **`CanPerform` calculation for per-record UI visibility**: New `AshGrant.Calculation.CanPerform` module produces per-record boolean values (e.g., `:can_update?`, `:can_destroy?`) that compile to SQL via `expression/2` — no N+1 queries. Supports RBAC scopes, instance permissions, deny-wins, and multi-scope OR combination. (#58)
- **`can_perform` DSL entity**: Declare individual CanPerform calculations inline in the `ash_grant` block with optional custom naming (e.g., `can_perform :read, name: :visible?`). The transformer auto-detects the resource module.
- **`can_perform_actions` batch option**: Generate multiple CanPerform calculations at once (e.g., `can_perform_actions [:update, :destroy]` generates `:can_update?` and `:can_destroy?`).
- **Compile-time action name validation**: `can_perform` and `can_perform_actions` now raise `Spark.Error.DslError` at compile time if a referenced action does not exist on the resource, preventing typos from silently producing always-false calculations. (#60)
- **`AshGrant.Info.can_perform_actions/1`**: Introspection helper to query configured batch actions.

## [0.11.1] - 2026-03-15

### Changed

- **Documentation**: Add domain-level DSL section to README with usage guidance, inheritance rules, and examples. Update installation version, feature list, and DSL Configuration table.
- **Developer tooling**: Add `/pr` and `/release` slash commands for streamlined PR and release workflows with built-in documentation gates. Update CLAUDE.md architecture section.

## [0.11.0] - 2026-03-15

### Added

- **Domain-level DSL (`AshGrant.Domain`)**: Define shared `resolver` and `scope` at the Ash Domain level. Resources using the `AshGrant` extension automatically inherit domain config, eliminating repeated `ash_grant do` blocks across resources. Resource-level settings take precedence (resolver override, same-name scope override). Cross-boundary scope inheritance is supported (resource scope can inherit from a domain-defined parent). (#54)

## [0.10.3] - 2026-03-15

### Fixed

- **`default_field_policies` includes PK/timestamps, fails on OTP 28**: When `field_group :admin, :all` is used with `default_field_policies true`, generated field policies now exclude primary keys and non-public attributes (e.g. `created_at`, `updated_at`). Previously these invalid fields caused `Spark.Error.DslError` on OTP 28 due to transformer ordering differences. (#51)

### Changed

- **Resolve all credo issues**: Fixed 82 credo warnings including `length/1` comparisons, `Enum.map_join` usage, negated conditions, nesting depth, and cyclomatic complexity. `mix credo` now reports zero issues.

## [0.10.2] - 2026-03-13

### Fixed

- **Overlapping field_policies with `:all` field_groups**: When multiple `field_group` definitions use `:all` (or `:all, except:`), resolved fields overlapped across policies. Since Ash requires ALL matching `field_policy` entries to pass, fields in multiple groups were denied even when the actor had the correct permission. `AddFieldPolicies` now deduplicates fields across groups so each field appears in exactly one policy. (#48)

## [0.10.1] - 2026-03-12

### Fixed

- **Action prefix patterns now match by Ash action type**: `read*` matches any `:read`-type action (e.g., `list_published`, `by_slug`, `search`), not just actions whose name starts with `"read"`. Same for `create*`, `update*`, `destroy*`. (#46)
- **Explainer prefix matching**: `Explainer.matches_action?/2` only did exact match — now uses `Permission.matches_action?/3` with full prefix and action-type support.

## [0.10.0] - 2026-03-12

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

[Unreleased]: https://github.com/jhlee111/ash_grant/compare/v0.10.2...HEAD
[0.10.2]: https://github.com/jhlee111/ash_grant/compare/v0.10.1...v0.10.2
[0.10.1]: https://github.com/jhlee111/ash_grant/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/jhlee111/ash_grant/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/jhlee111/ash_grant/compare/v0.8.1...v0.9.0
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

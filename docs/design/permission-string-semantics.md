# Permission string semantics: review and direction

**Status:** draft for discussion, 2026-11-27. Nothing here is decided until the co-maintainers agree on it.

This note records what `[!]resource:instance_id:action:scope[:field_group]` means, where the code disagrees with that meaning, and the order we plan to fix things in. It started as a follow-up to [PR #218](https://github.com/jhlee111/ash_grant/pull/218) (`deny_fields_by_default`).

- Section 2 records what the code does today.
- Section 3 is the model we propose.
- Sections 4 to 6 cover the findings, the decisions so far and the roadmap.

## 1. Why this note exists

Deny-wins was simple when a grant named one row. Scopes, instance ids, field groups, `scope_through` and the ceiling were added one at a time, and no one re-decided what the segments mean together. In particular, no one re-decided what `!` covers. Two problems followed:

1. **The string reads one way and runs another.** `!post:*:read:archived` denies every read, not just reads of archived posts. `!post:*:read:always:pii` denies the whole read instead of hiding `pii`.
2. **Code paths give different answers for the same string.** Field visibility is computed in four places that disagree. Instance ids were cast on some paths and compared as raw strings on others, which opened a deny bypass ([PR #229](https://github.com/jhlee111/ash_grant/pull/229)).

The second problem is the more urgent one, and it needs no grammar change.

## 2. What a string means today

This section describes `main` at `62309df`, plus [PR #229](https://github.com/jhlee111/ash_grant/pull/229).

**Parsing** splits on `:` and accepts 2 to 5 parts.

- A 3-part string becomes `r:*:a:s`, and a 2-part string becomes `r:*:a:` with no scope.
- An empty scope or field group becomes `nil`.
- Nothing is trimmed.

| Grant | Read | Create | Update / destroy | Generic action |
|---|---|---|---|---|
| RBAC `r:*:a:s` | Rows where `s` holds, OR-ed across grants | `s` checked against a virtual record built from the changeset | `s` (or its `write:` filter) checked against the stored record | Only a scope that needs no record passes |
| RBAC, empty scope | Nothing | Nothing | Nothing | Nothing |
| Instance `r:id:a[:s]` | `key in ids`, AND `s` when named. An undeclared `s` gives nothing and logs ([issue #207](https://github.com/jhlee111/ash_grant/issues/207)) | Never | The record whose key equals `id` | Never |
| `scope_through` parent grant | Child rows whose FK is the parent id. The parent grant's action is matched against the child's action | None | Yes | None |
| `!` RBAC | The whole action is denied. The scope is ignored | Denied | Denied | Denied |
| `!` instance | `not key in ids` | Ignored | Denied. With no record it fails closed | Ignored |
| 5th segment `:g` | The row, plus `g`'s fields (and its ancestors') on rows where that grant holds | Ignored | Ignored | Ignored |
| `!…:g` | Denies the whole action. `field_group_permissions` decides whether it is also logged (`:warn`) or raises (`:strict`) | Same | Same | Same |

**Field groups**

- Each field gets one field policy, owned by the first group in DSL order that lists it (`AddFieldPolicies`).
- A grant on `g` opens a field when the field's owning group is `g` or a group `g` inherits from.
- A group-less (4-part) grant opens every group when `deny_fields_by_default` is off, and none when it is on.
- A field in no group is visible to any row reader when the flag is off, and hidden when it is on (`UngroupedFieldCheck`).
- `:all` expands to attributes only.
- Masking is not inherited. It is allow-wins across the actor's groups and decided per record (`ApplyMasking`).

**Ceiling.** The grants and the ceiling are evaluated as two separate permission lists, and the results are intersected. This holds for rows, writes and each field group (`AshGrant.Ceiling`).

## 3. The model we propose

### Principles

1. **An allow names a region:** the records it hits (resource, instance, action, scope) times the fields it opens (the field-group segment). Grants combine by union, and the ceiling intersects.
2. **An instance id denotes a value of the instance key's type.** Two ids name the same record when they are equal once cast to that type, so `ABC…` and `abc…` are one UUID. [PR #229](https://github.com/jhlee111/ash_grant/pull/229) makes every runtime path compare ids this way.
3. **A deny covers records only.** Its scope narrows it, as a scope narrows an allow. A deny carries no field-group segment.
4. **Field visibility is allow-only.** Field exclusion is stated positively: with `except:` in the group definition, or with a ceiling for "at most these fields".
5. **`deny_fields_by_default` decides only what no grant names:** what a group-less grant opens, and whether fields in no group are visible.
6. **One function per question.** Every consumer gets the same answer for the same string, so the runtime, masking, `Introspect`, `Explainer` and the policy test tooling cannot drift.
7. **When a condition cannot be evaluated, fail toward less access.** An allow then authorizes nothing, as an instance grant with an undeclared scope already does ([issue #207](https://github.com/jhlee111/ash_grant/issues/207)). A deny then denies the whole action.

### Definitions

These definitions hold for one resource and one action $a$. $P^{+}$ and $P^{-}$ are the actor's allows and denies that match $a$, and each splits into RBAC and instance grants.

| Symbol | Meaning |
|---|---|
| $\mathrm{inst}(p)$ | `*` for RBAC, else the grant's instance id |
| $\mathrm{scope}(p)(r)$ | The grant's scope on record $r$. An empty scope is true on an instance grant and false on an RBAC grant (A3) |
| $\mathrm{grp}(p)$ | The field-group segment, or $\epsilon$ for a 4-part grant |
| $\doteq$ | Equality of instance-key values (principle 2) |
| $d$ | `deny_fields_by_default` |
| $F$ | Data fields: public attributes, public calculations and aggregates. CanPerform calculations are not data fields |
| $\Gamma$ | The resource's field groups. $\mathrm{fields}(G)$ is what $G$ lists, and $\mathrm{inh}^{*}(G)$ is $G$ with every group it reaches through `inherits` |
| $U_0$ | Fields in no group: $F \setminus \bigcup_{G \in \Gamma} \mathrm{fields}(G)$ |

**Rows.** A grant hits a record when its scope holds there and its instance id names the record:

$$
\mathrm{hit}(p, r) = \mathrm{scope}(p)(r) \land \big(\mathrm{inst}(p) = \ast \lor \mathrm{inst}(p) \doteq \mathrm{key}(r)\big)
$$

Today a deny ignores its scope:

$$
\mathrm{Row}_{\text{today}}(r) = \big(P^{-}_{\mathrm{rbac}} = \varnothing\big) \land \lnot\exists q \in P^{-}_{\mathrm{inst}}.\ \mathrm{inst}(q) \doteq \mathrm{key}(r) \land \exists p \in P^{+}.\ \mathrm{hit}(p, r)
$$

Under the proposed deny, a deny removes exactly the records it hits. $\mathrm{hit}^{\bot}$ is $\mathrm{hit}$ with an unevaluable scope counted as true (principle 7):

$$
\mathrm{Row}(r) = \exists p \in P^{+}.\ \mathrm{hit}(p, r) \land \lnot\exists q \in P^{-}.\ \mathrm{hit}^{\bot}(q, r)
$$

For `scope_through`, a parent grant $p$ also hits a child record $r$ when $\mathrm{inst}(p) \doteq \mathrm{fk}(r)$. A parent instance deny removes those grants.

**Fields.** A grant on group $G$ opens every field that $G$ or one of its ancestors lists, and `:all` lists every data field:

$$
[\![G]\!] = \bigcup_{H \in \mathrm{inh}^{*}(G)} \mathrm{fields}(H),
\qquad
\mathrm{fields}(G_{:all}) = F,
\qquad
[\![\epsilon]\!] = \begin{cases} F & d = 0 \\ \varnothing & d = 1 \end{cases}
$$

$$
\mathrm{Vis}(f, r) = \mathrm{Row}(r) \land \Big(\exists p \in P^{+}.\ \mathrm{hit}(p, r) \land f \in [\![\mathrm{grp}(p)]\!] \;\lor\; \big(f \in U_0 \land d = 0\big)\Big)
$$

A CanPerform calculation $c$ follows the row only: $\mathrm{Vis}(c, r) = \mathrm{Row}(r)$.

If `*` in the field-group segment is adopted, it opens every declared group: $[\![\ast]\!] = \bigcup_{G \in \Gamma} [\![G]\!]$. With $d = 0$ that equals a 4-part grant. With $d = 1$ it is everything a group can open.

$d$ appears in two places only: $[\![\epsilon]\!]$ and the $U_0$ term. $[\![G]\!]$ does not depend on it, which is what lets `:all` be expanded at compile time while $d$ is resolved at runtime.

**Ceiling.** $\mathrm{Row}$ and $\mathrm{Vis}$ are computed for the grants and for the ceiling separately, and the results are AND-ed.

**Writes.** A write is authorized when $\mathrm{Row}$ holds for the write action. A field-group segment has no meaning on a write.

### Where the implementation differs

Today a field is opened through its owning group only. $\pi(f)$ is the first group in DSL order that lists $f$:

$$
\mathrm{Vis}_{\text{today}}(f, r) = \mathrm{Row}_{\text{today}}(r) \land \Big(\exists p \in P^{+}.\ \mathrm{hit}(p, r) \land \pi(f) \in \mathrm{inh}^{*}(\mathrm{grp}(p)) \;\lor\; \big(f \in U_0^{\text{today}} \land d = 0\big)\Big)
$$

- **Today's rule implies the model's, but not the reverse.** They agree only when the groups listing a field form an `inherits` chain in DSL order, with $\pi(f)$ at the bottom. The test fixtures (`public ⊂ internal ⊂ admin`) are exactly that case, which is why the gap went unnoticed (F1 below).
- **`:all` lists attributes only.** So $U_0^{\text{today}}$ also holds every calculation and aggregate, even on a resource with an `:all` group (F2 below).

## 4. Findings

Most findings come from an independent code audit of `main` at `62309df`. The F rows come from a property test that compares real reads with the model above.

- **Verified:** reproduced with a test.
- **Read:** seen in code or a pinned test.
- **Inferred:** follows from the code, but no test exercises it.

**Access** says what a fix does: narrows access, widens it, or neither.

| ID | Finding | Evidence | Fix | Access |
|---|---|---|---|---|
| A1 | A field group on a write grant is ignored. `emp:*:*:always:public` limits reads to `public` fields but authorizes writes to any field. The static checker does not flag it | Read | D3: diagnose | Neither |
| A2 | `!` ignores its scope and field group. `!blog:*:update:own` denies every update | Read; `diagnostics/1` reports `:scoped_deny` and `check/2` reports `:deny_with_field_group` | D5 at 1.0 | Widens (scoped denies stop over-denying) |
| A3 | An empty scope means "nothing" on an RBAC grant and "unconditional" on an instance grant | Read; `:empty_rbac_scope` diagnostic | D6 | Neither |
| A4 | `*` means "any" only in the resource, instance and action segments. As a scope it is undeclared; as a field group it opens nothing | Read | D3 now, D4 for the group segment | Widens if `*` gets a meaning |
| A5 | Parsing is positional. An id containing `:` shifts every segment (`doc:urn:x:read:` gives action `x`), and whitespace is kept | Read (pinned by tests) | D3 now, D6 for escaping | Neither |
| A6 | `always`, `all` and `global` short-circuit by name. Redefining one with a filter only warns, and the scope still grants everything | Read | D3: compile error | Narrows |
| A7 | A parent instance grant's action is also the child's action. How far a parent deny reaches depends on its tier: a parent RBAC deny leaves the children writable, and a parent instance deny does not | Read (pinned by tests) | Open question; see [issue #214](https://github.com/jhlee111/ash_grant/issues/214) | — |
| B1 | Field visibility is computed four ways: `FieldFilterCheck`, `ApplyMasking`, `Introspect` and `PolicyTest.Assertions`. `assert_fields_hidden` passes on fields the runtime shows: a field in no group under a 5-part grant, and an instance-only grant (treated as `:no_access`) | Verified on `main` | D1 | Neither (tooling only gets stricter) |
| B2 | An instance type wildcard (`doc:id:@read:`) matches in `FilterCheck`, `Check` and `field_group_grants`, not in `CanPerform`, and `diagnostics/1` calls it dead | Read | [Issue #131](https://github.com/jhlee111/ash_grant/issues/131) | — |
| B3 | An unknown scope raises in `FilterCheck`, `Check` and `CanPerform`. It is silently `false` in `FieldFilterCheck`, and `false` plus a log line on an instance grant | Read | [Issue #141](https://github.com/jhlee111/ash_grant/issues/141) | — |
| B4 | Instance ids were cast on some paths and compared as raw strings on others. `post:<id>` with `!post:<ID>` hid the post, but its `scope_through` children stayed readable and updatable | Verified on `main` and v0.22.0 | D2, [PR #229](https://github.com/jhlee111/ash_grant/pull/229) | Narrows (the security fix); widens a few paths to match reads |
| B5 | `action:`/`resource:` check overrides apply to rows only. Field policies and masking use the real action name, and an override drops the action type, so `@type` grants never match there | Read | D1 | Neither |
| B6 | Field policies ignore `scope_through`. Grouped fields on child rows reached only through a parent grant are forbidden | Inferred | Open question | Widens if fixed |
| B7 | The guides say a 4-part grant shows all fields and a 5-part grant only the named group. That is wrong for fields in no group, and under `deny_fields_by_default` | Read | D1 plus a guide fix | Neither |
| F1 | Overlapping groups without `inherits` (`:public` lists `[:name]`, `:internal` and `:admin` are both `:all`): an `:admin` grant sees no field, and `:internal` cannot see `name` | Verified on `main`; the same code is in v0.22.0 | D4 | Widens |
| F2 | `:all` covers attributes only. Calculations and aggregates fall into $U_0$: visible to every row reader with the flag off, and to no one with it on | Verified on `main` | `:all` = attributes, public calculations and aggregates (not CanPerform) | Narrows with the flag off; widens with it on |
| F3 | `Evaluator.get_all_field_groups/5` returns `[]` for three different answers: denied, every field, and no group | Read | D1: return a tagged value | Neither |

## 5. Decisions so far

The owner of the original design made these decisions on 2026-11-26, and they still need co-maintainer review:

1. **Define the meaning first, then make the code match it.** Do not fit the definition to today's code.
2. **Fix consistency before changing the grammar** (D1, D2, D3). None of these fixes widens access.
3. **A deny covers records only, and its scope narrows it.** This is how IAM, Cedar, XACML, Ash `forbid_if` and PostgreSQL RESTRICTIVE policies treat a conditional deny (section 7). A deny that names a field group is rejected, not reinterpreted.
4. **Field exclusion stays positive.** Use `except:` in the group definition, or a ceiling for "at most these fields, whatever else the actor holds".
5. **`!` never changes meaning in place.** Narrowing a deny by its scope widens every stored scoped deny, and a stored string must not silently grant more. The narrowing deny therefore ships under a new spelling at 1.0. The existing diagnostics (`:scoped_deny`, `:deny_with_field_group`) find the strings to migrate.
6. **A deny whose scope cannot be evaluated denies the whole action.** This follows XACML's `Indeterminate{D}`, and mirrors how an allow with an undeclared scope authorizes nothing.

## 6. Roadmap

**Phase 0: done or in review**

- D2: instance ids compare as instance-key values on every runtime path ([PR #229](https://github.com/jhlee111/ash_grant/pull/229)). Fixes B4.

**Phase 1: no access widening**

- **D1: one field-visibility function.** It takes an optional record and returns a three-valued answer, as `PolicyTest.Checker` does for rows. `FieldFilterCheck`, `ApplyMasking`, `Introspect` and the policy test assertions all call it.
  - Fixes B1, B5, B7 and F3, and possibly B6.
  - The runtime answer does not change; `Introspect` and the test tooling become stricter.
- **D3: a wider checker and an opt-in strict mode.**
  - New diagnostic codes for a field group on a non-read action (A1), for `*`, blank or whitespace segments (A4, A5), and for the legacy 2- and 3-part forms.
  - Redefining a reserved scope name becomes a compile error (A6).
  - A `permission_syntax: :strict` setting raises at resolve time, as `IndeterminateMatch` does in `:strict`.

**Phase 2: widens access, each with a CHANGELOG security note**

- **D4: a field's policy accepts every group that lists it** (F1). The [issue #130](https://github.com/jhlee111/ash_grant/issues/130) dead-masking warning then can no longer fire, because masking works in either declaration order.
- **`:all` covers public calculations and aggregates** (F2). CanPerform stays out, since it reports the actor's permission, not row data.
- **Optional: `*` in the field-group segment** opens every declared group.
- The local spike branch already implements all three (section 9).

**Phase 3: 1.0**

- **D5: the records-only, narrowing deny under a new spelling** (A2). It fails closed wherever the scope cannot be evaluated: a create missing the attribute, a generic action, an undeclared scope. It touches the read NOT-filter, write evaluation, the per-row field predicate, `CanPerform`, `Introspect` and the policy test checker.
- **D6: a v2 grammar, only if D5 needs a new spelling anyway.**
  - A structured form becomes canonical, with a lossless string rendering and escaped ids. Maps are already accepted.
  - RBAC grants need an explicit scope.
  - A field segment is allowed on read-type actions only.
  - It fixes A1, A3, A4 and A5.
  - Migration needs a `to_v2/1` returning `{:ok, string} | {:ambiguous, reasons}` and a window where both forms parse.

## 7. Prior art

| System | Does a deny's condition narrow it? | Column-level negation | A deny that cannot be evaluated |
|---|---|---|---|
| AWS IAM | Yes | None. A deny on a DynamoDB attribute condition rejects the whole request | Fails open: a missing key makes the condition false |
| Cedar | Yes (`forbid … when`) | None | Fails open: a policy that errors is skipped |
| XACML 3.0 | Yes | None | Fails closed: `Indeterminate{D}` |
| Ash policies | Yes: `forbid_if X` compiles to `not X and …` | Field policies are AND-ed, so one forbid hides a field per record | — |
| PostgreSQL | RESTRICTIVE RLS policies are AND-ed row predicates | None. Column privileges are allow-lists, and revoking one column after a table grant has no effect | No policy means no rows |
| Lake Formation, Hasura | No deny | Column allow-lists. Lake Formation also has an exclude list inside one grant | — |

Every system with a conditional deny narrows it by the condition, and AshGrant is the outlier. Column control is an allow-list nearly everywhere, and "at most these columns" is expressed as an intersection cap, which AshGrant's ceiling already is.

## 8. Open questions

1. Does a records-only deny match how denies are used in practice? Does anyone rely on scoped or field-group denies?
2. Should Phase 2 land before 1.0, as separate PRs with security notes?
3. Is the tier-dependent reach of a parent deny (A7) the intended long-term meaning?
4. Should field groups follow `scope_through` (B6)?
5. Do Ash field policies run against the record a create or update returns, under the write action's name? If so, the field group on a write grant (A1) decides which fields come back, and a 4-part update grant could show fields the actor's read grant hides.
6. Under `deny_fields_by_default`, a ceiling made only of group-less grants hides every field. Is that intended?
7. What should `CanPerform` do with an instance `@type` grant ([issue #131](https://github.com/jhlee111/ash_grant/issues/131))?

## 9. Material

- **Spike branch `spike/field-visibility-model`** (local; it can be pushed on request).
  - `field_visibility_model_test.exs` is a property-test oracle: generated grants on six resources, with real reads compared against section 3.
  - Commits:
    - `e29e47e`: a field policy accepts every group that lists the field, and `:all` covers calculations and aggregates (F1, F2).
    - `0549c35`: `*` in the field-group segment.
    - `d297668`: the narrowing deny on reads (D5). Six existing tests that pin today's deny meaning fail on purpose.
- **`main` tests that pin today's behaviour.** `permission_edge_cases_test.exs` covers A5, `instance_write_test.exs` covers A7, and `field_group_permissions_test.exs` covers `!…:g`.

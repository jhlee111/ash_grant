# Scope Naming Convention

Scope names are the 4th segment of every permission string (`resource:instance:action:scope`)
and appear in resource definitions, domain modules, seed data, and policy tests. A consistent
naming convention makes permissions readable, composable, and easy to extend.

## The Sentence Test

Every scope name should complete this sentence naturally:

```
"Actor can [action] [resource] [scope]"
```

Read it aloud. If it sounds awkward, rename the scope.

```
"Actor can update own notification"             good
"Actor can read member at own unit"             good
"Actor can cancel schedule upcoming"            good
"Actor can read member subtree"                 awkward - what's a subtree?
"Actor can read post all"                       awkward - all what?
```

## Naming Rules

### Rule 1: Universal scope — use `always`

The unrestricted scope (expression `true`) should be named `:always`:

```elixir
scope :always, true
# "Actor can read member always"
```

> `:all` also works and is accepted by AshGrant, but `:always` reads more
> naturally as a predicate and avoids confusion with "all records" vs "all actions".

### Rule 2: Actor-relational scopes — preposition + `own_` + noun

For RBAC scopes that relate the record to the actor, use a preposition that
carries semantic meaning:

| Preposition | Meaning | Use when |
|-------------|---------|----------|
| `at_` | Specific location | Single org unit, branch, site |
| `in_` | Inside a container | Hierarchy, region, time period |
| `on_` | Part of a group | Team, roster, committee |
| `from_` / `to_` | Direction | Transfers, movements |

Examples:

```elixir
# "Actor can read member at own unit"
scope :at_own_unit, expr(org_unit_id in ^actor(:own_org_unit_ids))

# "Actor can read member in own tree"
scope :in_own_tree, expr(org_unit_id in ^actor(:subtree_org_unit_ids))

# "Actor can reset pin on own team"
scope :on_own_team, expr(user_id in ^actor(:team_member_ids))

# "Actor can read transfer from own unit"
scope :from_own_unit, expr(from_center_id in ^actor(:own_org_unit_ids))
```

The simple `:own` is kept for the common case of "my own record":

```elixir
# "Actor can update own notification"
scope :own, expr(user_id == ^actor(:id))
```

> **When the scoped attribute is not on the record itself** — e.g., Refund
> reaches `center_id` only through its `:order` relationship — write the
> expression against an action argument rather than traversing the
> relationship, and declare a `resolve_argument` to populate it:
>
> ```elixir
> scope :at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
> resolve_argument :center_id, from_path: [:order, :center_id]
> ```
>
> The scope name stays `:at_own_unit` (the sentence test still passes:
> "Actor can update refund at own unit"). See the
> [Argument-Based Scope guide](argument-based-scope.md) for the full rationale.

### Rule 3: Resource state scopes — adjectives or participles

For ABAC scopes based on record attributes, use names that describe the state:

```elixir
scope :published, expr(status == :published)
scope :draft, expr(status == :draft)
scope :editable, expr(status in [:draft, :pending_review])
scope :upcoming, expr(status == :scheduled and start_at > now())
scope :active, expr(is_active == true)
scope :small_amount, expr(amount < 1000)
```

Prefer **semantic names** over technical listings:

```elixir
# Semantic - tells you WHAT
scope :editable, expr(status in [:draft, :pending_review])

# Technical listing - tells you HOW (avoid)
scope :draft_or_pending, expr(status in [:draft, :pending_review])
```

More examples: `:cancellable` > `:scheduled_and_future`, `:archivable` > `:completed_or_expired`.

### Rule 4: AND composition — `_and_` connector with scope inheritance

When a scope requires multiple conditions to ALL be true, use scope inheritance
and name with `_and_`:

```elixir
scope :own, expr(author_id == ^actor(:id))
scope :own_and_draft, [:own], expr(status == :draft)
# Result: author_id == actor.id AND status == :draft
# "Actor can update post own and draft"
```

```elixir
scope :at_own_unit, expr(org_unit_id in ^actor(:own_org_unit_ids))
scope :at_own_unit_and_upcoming, [:at_own_unit], expr(status == :scheduled and start_at > now())
# "Actor can cancel schedule at own unit and upcoming"
```

### Rule 5: OR composition — multiple permissions, not compound scopes

When access should be granted if ANY condition is true, use separate scopes with
separate permissions. AshGrant ORs multiple permissions automatically:

```elixir
# Resource defines two atomic scopes:
scope :from_own_unit, expr(from_center_id in ^actor(:own_org_unit_ids))
scope :to_own_unit, expr(to_center_id in ^actor(:own_org_unit_ids))

# Role gets both permissions - AshGrant ORs them:
# "transfer:*:read:from_own_unit", "transfer:*:read:to_own_unit"
# Result: from my unit OR to my unit
```

> **Key rule:** Multiple permissions = OR. Scope inheritance = AND.

## Quick Reference

| Scope | Expression pattern | Sentence |
|-------|-------------------|----------|
| `always` | `true` | "Actor can read member **always**" |
| `own` | `user_id == ^actor(:id)` | "Actor can update **own** notification" |
| `at_own_unit` | `org_unit_id in ^actor(:unit_ids)` | "Actor can read member **at own unit**" |
| `in_own_tree` | `org_unit_id in ^actor(:tree_ids)` | "Actor can read member **in own tree**" |
| `on_own_team` | `user_id in ^actor(:team_ids)` | "Actor can reset pin **on own team**" |
| `from_own_unit` | `from_id in ^actor(:unit_ids)` | "Actor can read transfer **from own unit**" |
| `to_own_unit` | `to_id in ^actor(:unit_ids)` | "Actor can read transfer **to own unit**" |
| `published` | `status == :published` | "Actor can read post **published**" |
| `draft` | `status == :draft` | "Actor can update doc **draft**" |
| `editable` | `status in [:draft, :pending]` | "Actor can update doc **editable**" |
| `upcoming` | `start_at > now()` | "Actor can cancel schedule **upcoming**" |

## Examples

### Staff Device PIN

```elixir
ash_grant do
  resource_name "staff_pin"
  default_policies true

  scope :always, true
  scope :own, expr(user_id == ^actor(:id))
  scope :on_own_team, expr(user_id in ^actor(:team_member_ids))
end
```

```
Staff:          "staff_pin:*:read:own", "staff_pin:*:set_pin:own"
Center Manager: "staff_pin:*:read:on_own_team", "staff_pin:*:set_pin:on_own_team"
Admin:          "staff_pin:*:*:always"
```

### Member Management

```elixir
ash_grant do
  resource_name "member"
  default_policies true

  scope :always, true
  scope :at_own_unit, expr(home_center_id in ^actor(:own_org_unit_ids))
  scope :in_own_tree, expr(home_center_id in ^actor(:subtree_org_unit_ids))
end
```

```
Staff:            "member:*:read:at_own_unit"
Regional Manager: "member:*:read:in_own_tree"
Executive:        "member:*:read:always"
```

### Inventory Transfer (OR composition)

```elixir
ash_grant do
  resource_name "inventory_transfer"
  default_policies true

  scope :always, true
  scope :from_own_unit, expr(from_location.org_unit_id in ^actor(:own_org_unit_ids))
  scope :to_own_unit, expr(to_location.org_unit_id in ^actor(:own_org_unit_ids))
  scope :in_own_tree, expr(
    from_location.org_unit_id in ^actor(:subtree_org_unit_ids) or
    to_location.org_unit_id in ^actor(:subtree_org_unit_ids)
  )
end
```

```
Center Manager: "inventory_transfer:*:read:from_own_unit", "inventory_transfer:*:read:to_own_unit"
Regional:       "inventory_transfer:*:read:in_own_tree"
```

### Schedule with Lifecycle (AND composition)

```elixir
ash_grant do
  resource_name "schedule"
  default_policies true

  scope :always, true
  scope :at_own_unit, expr(org_unit_id in ^actor(:own_org_unit_ids))
  scope :upcoming, expr(status == :scheduled and start_at > now())
  scope :at_own_unit_and_upcoming, [:at_own_unit], expr(status == :scheduled and start_at > now())
end
```

```
Center Manager: "schedule:*:cancel:at_own_unit_and_upcoming"
Admin:          "schedule:*:cancel:always"
```

## Checklist for New Scopes

1. Write the sentence: "Actor can [action] [resource] [your_scope_name]"
2. Read it aloud — does it sound natural?
3. Is it a predicate (true/false about the record), not a noun or role name?
4. Does the preposition match the relationship? (`at_` location, `in_` container, `on_` group)
5. For ABAC: does the name convey business meaning, not technical implementation?
6. For OR conditions: can you split into separate scopes + permissions instead?
7. For AND conditions: does `_and_` clearly show the composition?

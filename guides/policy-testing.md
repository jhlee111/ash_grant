# Policy Testing

AshGrant provides a DSL-based testing framework for verifying policy configurations without requiring a database. This tests **policy configuration**, not data — no database records needed.

## Resource Setup

Policy tests verify how your resolver converts roles to permissions. Use any resource with an `ash_grant` block configured (see the [Getting Started guide](getting-started.md)).

## DSL-Based Tests

Write policy tests to verify the resolver and scope configuration:

```elixir
defmodule MyApp.PolicyTests.PostPolicyTest do
  use AshGrant.PolicyTest

  resource MyApp.Post

  actor :admin, %{role: :admin}
  actor :editor, %{role: :editor, id: "editor_001"}
  actor :viewer, %{role: :viewer}

  describe "read access" do
    test "editor can read all posts" do
      assert_can :editor, :read
    end

    test "viewer can read published posts" do
      assert_can :viewer, :read, %{status: :published}
    end

    test "viewer cannot read drafts" do
      assert_cannot :viewer, :read, %{status: :draft}
    end
  end

  describe "write access" do
    test "editor can update own posts" do
      assert_can :editor, :update, %{author_id: "editor_001"}
    end

    test "editor cannot update others posts" do
      assert_cannot :editor, :update, %{author_id: "other_user"}
    end

    test "viewer cannot update any posts" do
      assert_cannot :viewer, :update
    end
  end
end
```

## Assertion Macros

| Macro | Description |
|-------|-------------|
| `assert_can(actor, action)` | Actor can perform action |
| `assert_can(actor, action, record)` | Actor can access specific record (bare map) |
| `assert_can(actor, action, [record: ..., arguments: ...])` | Actor can access record with action arguments |
| `assert_cannot(actor, action)` | Actor cannot perform action |
| `assert_cannot(actor, action, record)` | Actor cannot access specific record (bare map) |
| `assert_cannot(actor, action, [record: ..., arguments: ...])` | Actor cannot access record with action arguments |

Action can be specified as:
- Atom: `:read` (shorthand for `action: :read`)
- Keyword: `action: :approve` (specific action name)
- Keyword: `action_type: :update` (all actions of type)

### Testing argument-based scopes

For scopes that reference `^arg(:name)` (see
[Argument-Based Scope](argument-based-scope.md)), pass an `arguments:` map
alongside `record:` using the keyword-list form:

```elixir
assert_can :manager, :update,
  record: %{author_id: "u1"},
  arguments: %{center_id: "center_A"}

assert_cannot :manager, :update,
  record: %{author_id: "u1"},
  arguments: %{center_id: "outside_unit"}
```

The `arguments` map is forwarded to `Ash.Expr.fill_template` as `:args`, so
the scope's `^arg(:center_id)` resolves to the supplied value before
evaluation against the record.

## YAML Format

Policy tests can also be written in YAML for non-developers or interchange:

```yaml
resource: MyApp.Post

actors:
  editor:
    role: editor
    id: "editor_001"
  viewer:
    role: viewer

tests:
  - name: "editor can read all posts"
    assert_can:
      actor: editor
      action: read

  - name: "viewer can read published posts"
    assert_can:
      actor: viewer
      action: read
      record:
        status: published

  - name: "viewer cannot read drafts"
    assert_cannot:
      actor: viewer
      action: read
      record:
        status: draft

  - name: "editor can update own posts"
    assert_can:
      actor: editor
      action: update
      record:
        author_id: "editor_001"

  - name: "editor cannot update others posts"
    assert_cannot:
      actor: editor
      action: update
      record:
        author_id: "other_user"
```

### YAML — `arguments:` field for argument-based scopes

YAML tests can provide action arguments for scopes that use `^arg(:name)`:

```yaml
  - name: "manager can update refund in their unit"
    assert_can:
      actor: unit_manager
      action: update
      record:
        author_id: "u1"
      arguments:
        center_id: "center_A"

  - name: "manager cannot update refund outside their unit"
    assert_cannot:
      actor: unit_manager
      action: update
      record:
        author_id: "u1"
      arguments:
        center_id: "center_Z"
```

See [Argument-Based Scope](argument-based-scope.md) for when to use this pattern.

## Mix Tasks

**Run policy tests:**

```bash
# Run DSL tests
mix ash_grant.verify test/policy_tests/

# Run YAML tests
mix ash_grant.verify priv/policy_tests/document.yaml

# Verbose output
mix ash_grant.verify test/policy_tests/ --verbose
```

**Export policies:**

```bash
# Export to YAML
mix ash_grant.export MyApp.Document --format=yaml

# Export to Mermaid diagram
mix ash_grant.export MyApp.Document --format=mermaid

# Export to Markdown documentation
mix ash_grant.export MyApp.Document --format=markdown

# Export to file
mix ash_grant.export MyApp.Document --format=markdown --output=docs/document.md
```

**Import YAML to DSL:**

```bash
# Generate DSL code from YAML (output to stdout)
mix ash_grant.import priv/policy_tests/document.yaml

# Generate and write to file
mix ash_grant.import priv/policy_tests/document.yaml --output=test/policy_tests/document_test.exs
```

## Running Policy Tests Programmatically

Use the `AshGrant.PolicyTest.Runner` module:

```elixir
# Run a single module
results = AshGrant.PolicyTest.Runner.run_module(MyApp.PolicyTests.DocumentPolicyTest)

# Run all policy test modules
summary = AshGrant.PolicyTest.Runner.run_all()
# => %{passed: 10, failed: 0, results: [...]}

# Run specific modules
summary = AshGrant.PolicyTest.Runner.run_all(modules: [DocumentPolicyTest, PostPolicyTest])
```

## Dependencies

To use YAML format, add `yaml_elixir` to your dependencies:

```elixir
def deps do
  [
    {:yaml_elixir, "~> 2.9"}
  ]
end
```

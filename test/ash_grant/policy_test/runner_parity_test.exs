# The fixtures live outside the ExUnit module: nested there, `use AshGrant.PolicyTest`'s
# `test/2` would collide with the one ExUnit.Case imports.

defmodule AshGrant.PolicyTest.RunnerParity.Schedule do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    extensions: [AshGrant]

  ash_grant do
    resolver(fn actor, _context -> (actor && Map.get(actor, :permissions)) || [] end)
    resource_name("schedule")

    scope(:always, true)
    scope(:online_content, expr(type == :online_education))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:type, :atom, public?: true)
  end

  actions do
    defaults([:read])

    update :cancel do
      accept([])
    end

    update :reschedule do
      accept([])
    end
  end
end

defmodule AshGrant.PolicyTest.RunnerParity.SchedulePolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.PolicyTest.RunnerParity.Schedule)

  actor(:director, %{
    permissions: ["schedule:*:cancel:online_content", "schedule:*:*:always"]
  })

  actor(:split, %{
    permissions: ["schedule:*:cancel:online_content", "schedule:*:reschedule:always"]
  })

  actor(:content_manager, %{permissions: ["schedule:*:cancel:online_content"]})

  test "a later grant's scope admits the record" do
    assert_can(:director, :cancel, %{type: :in_person})
  end

  test "the only grant's scope rejects the record" do
    assert_cannot(:content_manager, :cancel, %{type: :in_person})
  end

  test "an action_type assertion holds when any action of the type admits the record" do
    assert_can(:split, [action_type: :update], %{type: :in_person})
  end
end

defmodule AshGrant.PolicyTest.RunnerParity.InstancePolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Post)

  actor(:post_reader, %{permissions: ["post:post_123:read:"]})

  test "an instance grant admits its own record" do
    assert_can(:post_reader, :read, %{id: "post_123"})
  end

  test "an instance grant does not admit another record" do
    assert_cannot(:post_reader, :read, %{id: "post_999"})
  end
end

defmodule AshGrant.PolicyTest.RunnerParity.ScopeThroughPolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.ChildComment)

  actor(:post_reader, %{permissions: ["post:post_123:read:"]})

  test "a parent instance grant admits that parent's children" do
    assert_can(:post_reader, :read, %{post_id: "post_123"})
  end

  test "a parent instance grant does not admit another parent's children" do
    assert_cannot(:post_reader, :read, %{post_id: "post_999"})
  end
end

defmodule AshGrant.PolicyTest.RunnerParityTest do
  @moduledoc """
  The DSL and YAML runners must give the same answer, and it must be the
  runtime's: a record passes when ANY component of the read-side union admits
  it — any grant's scope (#123), a matching instance ID, or a scope_through
  parent instance ID (#143).

  Each scenario is written once as a DSL module and once as YAML; both must
  pass every test.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.{Runner, YamlParser}

  alias AshGrant.PolicyTest.RunnerParity.{
    InstancePolicyTest,
    SchedulePolicyTest,
    ScopeThroughPolicyTest
  }

  @moduletag :tmp_dir

  @schedule_yaml """
  resource: AshGrant.PolicyTest.RunnerParity.Schedule

  actors:
    director:
      permissions:
        - "schedule:*:cancel:online_content"
        - "schedule:*:*:always"
    split:
      permissions:
        - "schedule:*:cancel:online_content"
        - "schedule:*:reschedule:always"
    content_manager:
      permissions:
        - "schedule:*:cancel:online_content"

  tests:
    - name: "a later grant's scope admits the record"
      assert_can:
        actor: director
        action: cancel
        record:
          type: in_person

    - name: "the only grant's scope rejects the record"
      assert_cannot:
        actor: content_manager
        action: cancel
        record:
          type: in_person

    - name: "an action_type assertion holds when any action of the type admits the record"
      assert_can:
        actor: split
        action_type: update
        record:
          type: in_person
  """
  @instance_yaml """
  resource: AshGrant.Test.Post

  actors:
    post_reader:
      permissions:
        - "post:post_123:read:"

  tests:
    - name: "an instance grant admits its own record"
      assert_can:
        actor: post_reader
        action: read
        record:
          id: "post_123"

    - name: "an instance grant does not admit another record"
      assert_cannot:
        actor: post_reader
        action: read
        record:
          id: "post_999"
  """
  @scope_through_yaml """
  resource: AshGrant.Test.ChildComment

  actors:
    post_reader:
      permissions:
        - "post:post_123:read:"

  tests:
    - name: "a parent instance grant admits that parent's children"
      assert_can:
        actor: post_reader
        action: read
        record:
          post_id: "post_123"

    - name: "a parent instance grant does not admit another parent's children"
      assert_cannot:
        actor: post_reader
        action: read
        record:
          post_id: "post_999"
  """

  defp outcomes(results), do: Map.new(results, &{&1.test_name, {&1.passed, &1.message}})

  defp assert_both_pass(module, yaml, dir) do
    path = Path.join(dir, "parity.yaml")
    File.write!(path, yaml)

    dsl = module |> Runner.run_module() |> outcomes()
    {:ok, yaml_results} = YamlParser.run_yaml_tests(path)
    yaml = outcomes(yaml_results)

    assert Map.keys(dsl) == Map.keys(yaml)

    for {name, outcome} <- dsl do
      assert outcome == {true, nil}, "DSL: #{name}: #{inspect(outcome)}"
      assert yaml[name] == {true, nil}, "YAML: #{name}: #{inspect(yaml[name])}"
    end
  end

  test "scopes are OR-composed across grants and across actions of a type", %{tmp_dir: dir} do
    assert_both_pass(SchedulePolicyTest, @schedule_yaml, dir)
  end

  test "an instance grant admits only its own record", %{tmp_dir: dir} do
    assert_both_pass(InstancePolicyTest, @instance_yaml, dir)
  end

  test "a scope_through grant admits only its parent's children", %{tmp_dir: dir} do
    assert_both_pass(ScopeThroughPolicyTest, @scope_through_yaml, dir)
  end

  test "a YAML test naming an undefined actor fails like the DSL does", %{tmp_dir: dir} do
    path = Path.join(dir, "typo.yaml")

    File.write!(path, """
    resource: AshGrant.Test.Post

    actors:
      guest:
        permissions: []

    tests:
      - name: "gust cannot read"
        assert_cannot:
          actor: gust
          action: read
    """)

    assert {:ok, [result]} = YamlParser.run_yaml_tests(path)
    refute result.passed
    assert result.message =~ "Actor :gust not defined. Available actors: [:guest]"
  end
end

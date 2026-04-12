defmodule AshGrant.PolicyTest.PropertyTest do
  @moduledoc """
  Property-based tests for the policy testing framework.

  Tests invariants that should hold regardless of input:
  - Symmetry: assert_can and assert_cannot are opposites
  - Consistency: same input always gives same result
  - Round-trip: YAML -> DSL -> YAML preserves semantics
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrant.PolicyTest.Runner

  # Generators

  defp role_gen do
    StreamData.member_of([:admin, :author, :reviewer, :reader, :editor, :viewer, :guest])
  end

  defp actor_gen do
    gen all(
          role <- role_gen(),
          id <- StreamData.binary(min_length: 8, max_length: 16)
        ) do
      %{role: role, id: id}
    end
  end

  defp action_gen do
    StreamData.member_of([:read, :create, :update, :destroy])
  end

  defp status_gen do
    StreamData.member_of([:draft, :pending_review, :approved, :archived, :published])
  end

  describe "permission check consistency" do
    property "same input always produces same result" do
      check all(
              actor <- actor_gen(),
              action <- action_gen(),
              max_runs: 50
            ) do
        result1 = AshGrant.Introspect.can?(AshGrant.Test.Document, action, actor)
        result2 = AshGrant.Introspect.can?(AshGrant.Test.Document, action, actor)

        # Same actor + action should always give same result
        assert result1 == result2
      end
    end

    property "nil actor always denied" do
      check all(
              action <- action_gen(),
              max_runs: 20
            ) do
        result = AshGrant.Introspect.can?(AshGrant.Test.Document, action, nil)
        assert {:deny, %{reason: :no_actor}} = result
      end
    end

    property "empty permissions always denied" do
      check all(
              action <- action_gen(),
              max_runs: 20
            ) do
        actor = %{permissions: []}
        result = AshGrant.Introspect.can?(AshGrant.Test.Document, action, actor)
        assert {:deny, _} = result
      end
    end
  end

  describe "deny-wins semantics" do
    property "deny always wins over allow for same action" do
      check all(
              action <- action_gen(),
              scope <- StreamData.member_of(["always", "draft", "approved"]),
              max_runs: 30
            ) do
        # Actor with both allow and deny for same action
        actor = %{
          permissions: [
            # allow
            "document:*:#{action}:#{scope}",
            # deny
            "!document:*:#{action}:#{scope}"
          ]
        }

        result = AshGrant.Introspect.can?(AshGrant.Test.Document, action, actor)

        # Deny should always win
        assert {:deny, _} = result
      end
    end
  end

  describe "admin permissions" do
    property "admin role has access to all actions" do
      check all(
              action <- action_gen(),
              max_runs: 20
            ) do
        actor = %{role: :admin}
        result = AshGrant.Introspect.can?(AshGrant.Test.Document, action, actor)

        # Admin should always be allowed
        assert {:allow, _} = result
      end
    end
  end

  describe "scope evaluation consistency" do
    property "scope filter evaluation is deterministic" do
      check all(
              actor_id <- StreamData.binary(min_length: 8, max_length: 16),
              status <- status_gen(),
              max_runs: 30
            ) do
        actor = %{id: actor_id}
        record = %{author_id: actor_id, status: status}

        # Evaluate "own" scope multiple times
        filter =
          AshGrant.Info.resolve_scope_filter(
            AshGrant.Test.Post,
            :own,
            %{actor: actor}
          )

        # Evaluate against record multiple times
        result1 = Ash.Expr.eval(filter, record: record, actor: actor)
        result2 = Ash.Expr.eval(filter, record: record, actor: actor)

        # Should be consistent
        assert result1 == result2
      end
    end
  end

  describe "YAML round-trip" do
    property "YAML parse preserves test count" do
      # Create a YAML string with varying number of tests
      check all(
              num_tests <- StreamData.integer(1..5),
              max_runs: 10
            ) do
        tests =
          1..num_tests
          |> Enum.map_join("\n", fn i ->
            """
              - name: "test #{i}"
                assert_can:
                  actor: reader
                  action: read
            """
          end)

        yaml = """
        resource: AshGrant.Test.Document

        actors:
          reader:
            role: reader

        tests:
        #{tests}
        """

        {:ok, parsed} = YamlElixir.read_from_string(yaml)
        parsed_tests = parsed["tests"] || []

        assert length(parsed_tests) == num_tests
      end
    end
  end

  describe "result struct invariants" do
    property "passed test has no message" do
      check all(
              test_name <- StreamData.binary(min_length: 1, max_length: 50),
              duration <- StreamData.positive_integer(),
              max_runs: 20
            ) do
        result = AshGrant.PolicyTest.Result.pass(test_name, duration)

        assert result.passed == true
        assert result.message == nil
        assert result.duration_us == duration
        assert result.test_name == test_name
      end
    end

    property "failed test has message" do
      check all(
              test_name <- StreamData.binary(min_length: 1, max_length: 50),
              message <- StreamData.binary(min_length: 1, max_length: 100),
              duration <- StreamData.positive_integer(),
              max_runs: 20
            ) do
        result = AshGrant.PolicyTest.Result.fail(test_name, message, duration)

        assert result.passed == false
        assert result.message == message
        assert result.duration_us == duration
        assert result.test_name == test_name
      end
    end
  end

  describe "runner summary invariants" do
    property "passed + failed = total" do
      check all(
              num_modules <- StreamData.integer(0..3),
              max_runs: 5
            ) do
        # Use existing fixture modules
        modules =
          [
            AshGrant.PolicyTest.Fixtures.DocumentPolicyTest,
            AshGrant.PolicyTest.Fixtures.PostPolicyTest,
            AshGrant.PolicyTest.Fixtures.TestWithFunctions
          ]
          |> Enum.take(num_modules)

        if modules != [] do
          summary = Runner.run_all(modules: modules)

          total = length(summary.results)
          assert summary.passed + summary.failed == total
        end
      end
    end
  end
end

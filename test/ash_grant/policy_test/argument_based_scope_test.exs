defmodule AshGrant.PolicyTest.ArgumentBasedScopeTest do
  @moduledoc """
  Tests that `AshGrant.PolicyTest` covers argument-based scopes through both
  the DSL (`assert_can`/`assert_cannot` with `arguments:`) and the YAML
  format (an `arguments:` field on a test).

  The DSL path has its own assertions module; the YAML path has an
  internal duplicate inside `YamlParser`. Both must forward the
  `arguments` map to `Ash.Expr.fill_template` via `args:` for `^arg(...)`
  templates to resolve during scope evaluation.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.{Assertions, YamlParser}

  @yaml_fixture "test/fixtures/policy_tests/argument_based_scope.yaml"

  describe "DSL assertions — keyword-list third arg" do
    test "assert_can passes when arguments satisfy the argument-based scope" do
      filter =
        AshGrant.Info.resolve_scope_filter(
          AshGrant.Test.Auth.RefundDsl,
          :at_own_unit,
          %{}
        )

      actor = %{id: "u1", own_org_unit_ids: ["center_A"]}
      record = %{author_id: "u1"}
      arguments = %{center_id: "center_A"}

      assert Assertions.evaluate_filter_against_record(
               filter,
               record,
               actor,
               AshGrant.Test.Auth.RefundDsl,
               arguments
             )
    end

    test "assert_cannot is correct when argument does not match actor's units" do
      filter =
        AshGrant.Info.resolve_scope_filter(
          AshGrant.Test.Auth.RefundDsl,
          :at_own_unit,
          %{}
        )

      actor = %{id: "u1", own_org_unit_ids: ["center_A"]}
      record = %{author_id: "u1"}
      arguments = %{center_id: "center_Z"}

      refute Assertions.evaluate_filter_against_record(
               filter,
               record,
               actor,
               AshGrant.Test.Auth.RefundDsl,
               arguments
             )
    end

    test "default arguments (empty map) still works for scopes that don't use ^arg(...)" do
      filter =
        AshGrant.Info.resolve_scope_filter(
          AshGrant.Test.Auth.RefundDsl,
          :by_own_author,
          %{}
        )

      actor = %{id: "u1"}
      record = %{author_id: "u1"}

      # 4-arity form (no arguments) must keep working for legacy callers.
      assert Assertions.evaluate_filter_against_record(
               filter,
               record,
               actor,
               AshGrant.Test.Auth.RefundDsl
             )
    end
  end

  describe "YAML parser — parses and forwards :arguments" do
    test "parse_file picks up the arguments field on a test" do
      {:ok, parsed} = YamlParser.parse_file(@yaml_fixture)

      manager_test =
        Enum.find(parsed.tests, &(&1.name =~ "manager can update"))

      # YamlParser intentionally keeps mixed-case/quoted strings (UUIDs etc.)
      # as strings; only lowercase-alphanum tokens atomize.
      assert manager_test.arguments == %{center_id: "center_A"}
    end

    test "tests without arguments get an empty map" do
      {:ok, parsed} = YamlParser.parse_file(@yaml_fixture)

      author_test = Enum.find(parsed.tests, &(&1.name =~ "author can update own"))

      assert author_test.arguments == %{}
    end

    test "running the fixture passes every assertion" do
      {:ok, results} = YamlParser.run_yaml_tests(@yaml_fixture)

      failed = Enum.reject(results, & &1.passed)

      assert failed == [],
             "expected every test in #{@yaml_fixture} to pass, but these failed:\n" <>
               Enum.map_join(failed, "\n", &"  - #{&1.test_name}: #{&1.message}")
    end
  end

  describe "DslGenerator — converts YAML arguments to DSL" do
    test "generated DSL uses the keyword-list third-arg form when arguments are set" do
      parsed = YamlParser.parse_file!(@yaml_fixture)
      code = AshGrant.PolicyTest.DslGenerator.generate_from_parsed(parsed, @yaml_fixture)

      # The manager test had both record: and arguments:, so expect the
      # keyword-list form.
      assert code =~ "arguments: %{center_id:"
      assert code =~ "record:"

      # The author test had only record:, so the simple 3-arg form should
      # still be used.
      assert code =~ ~r/assert_can :author_user, :update, %\{author_id:/
    end
  end
end

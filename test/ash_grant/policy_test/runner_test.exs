defmodule AshGrant.PolicyTest.RunnerTest do
  @moduledoc """
  Tests for the PolicyTest runner.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.Runner
  alias AshGrant.PolicyTest.Result

  # Fixture modules from test/support/policy_test_fixtures.ex
  alias AshGrant.PolicyTest.Fixtures.{
    DocumentPolicyTest,
    GenericActionPolicyTest,
    PostPolicyTest,
    TestWithResource
  }

  describe "run_module/1" do
    test "runs all tests in a module and returns results" do
      results = Runner.run_module(DocumentPolicyTest)

      assert is_list(results)
      assert results != []

      # All results should be Result structs
      Enum.each(results, fn result ->
        assert %Result{} = result
        assert is_binary(result.test_name)
        assert is_boolean(result.passed)
        assert is_integer(result.duration_us)
      end)
    end

    test "all passing tests return passed: true" do
      results = Runner.run_module(DocumentPolicyTest)

      # All tests in DocumentPolicyTest should pass
      assert Enum.all?(results, & &1.passed)
    end

    test "returns empty list for module with no tests" do
      results = Runner.run_module(TestWithResource)

      assert results == []
    end

    test "captures test names correctly" do
      results = Runner.run_module(DocumentPolicyTest)

      test_names = Enum.map(results, & &1.test_name)

      assert "admin can do anything" in test_names
      assert "reader can read" in test_names
      assert "guest cannot read" in test_names
    end
  end

  describe "run_all/1" do
    test "runs multiple modules and returns summary" do
      summary =
        Runner.run_all(modules: [DocumentPolicyTest, PostPolicyTest])

      assert is_map(summary)
      assert Map.has_key?(summary, :passed)
      assert Map.has_key?(summary, :failed)
      assert Map.has_key?(summary, :results)

      assert summary.passed >= 0
      assert summary.failed >= 0
      assert is_list(summary.results)
    end

    test "counts passed and failed tests correctly" do
      summary =
        Runner.run_all(modules: [DocumentPolicyTest])

      # All DocumentPolicyTest tests should pass
      assert summary.failed == 0
      assert summary.passed == length(summary.results)
    end

    test "generic action policy tests all pass" do
      summary =
        Runner.run_all(modules: [GenericActionPolicyTest])

      assert summary.failed == 0
      assert summary.passed == length(summary.results)
      assert summary.passed > 0
    end

    test "includes module name in results" do
      summary =
        Runner.run_all(modules: [DocumentPolicyTest])

      Enum.each(summary.results, fn result ->
        assert result.module == DocumentPolicyTest
      end)
    end
  end

  describe "discover_modules/1" do
    defp policy_source(module_name) do
      """
      defmodule #{module_name} do
        use AshGrant.PolicyTest

        resource(AshGrant.Test.Document)

        actor(:reader, %{role: :reader})

        test "reader can read" do
          assert_can(:reader, :read)
        end
      end
      """
    end

    defp write(dir, name, content) do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      path
    end

    test "uses already-compiled modules without compiling them again" do
      modules = Runner.discover_modules("test/support")

      assert DocumentPolicyTest in modules
      assert GenericActionPolicyTest in modules
      # Compiling the file again would have moved the loaded version to old code.
      refute :erlang.check_old_code(DocumentPolicyTest)
    end

    @tag :tmp_dir
    test "finds modules in .exs files", %{tmp_dir: dir} do
      write(dir, "nested/reader_policy_test.exs", policy_source("RunnerDiscovery.ExsPolicyTest"))

      assert Runner.discover_modules(dir) == [RunnerDiscovery.ExsPolicyTest]
    end

    @tag :tmp_dir
    test "finds modules in .ex files outside the compile path", %{tmp_dir: dir} do
      write(dir, "reader_policy_test.ex", policy_source("RunnerDiscovery.UncompiledPolicyTest"))

      assert Runner.discover_modules(dir) == [RunnerDiscovery.UncompiledPolicyTest]
    end

    @tag :tmp_dir
    test "a file path yields only that file's modules", %{tmp_dir: dir} do
      path = write(dir, "a_policy_test.exs", policy_source("RunnerDiscovery.FileAPolicyTest"))
      write(dir, "b_policy_test.exs", policy_source("RunnerDiscovery.FileBPolicyTest"))

      assert Runner.discover_modules(path) == [RunnerDiscovery.FileAPolicyTest]
    end

    @tag :tmp_dir
    test "skips modules that are not policy tests", %{tmp_dir: dir} do
      write(
        dir,
        "with_helper_policy_test.exs",
        """
        defmodule RunnerDiscovery.Helper do
          def role, do: :reader
        end

        #{policy_source("RunnerDiscovery.WithHelperPolicyTest")}
        """
      )

      assert Runner.discover_modules(dir) == [RunnerDiscovery.WithHelperPolicyTest]
    end

    @tag :tmp_dir
    test "raises when a policy test file does not compile", %{tmp_dir: dir} do
      write(
        dir,
        "broken_policy_test.exs",
        "defmodule RunnerDiscovery.Broken do\n  use AshGrant.PolicyTest\n"
      )

      assert_raise TokenMissingError, fn -> Runner.discover_modules(dir) end
    end
  end

  describe "Result struct" do
    test "has expected fields" do
      result = %Result{
        test_name: "test name",
        passed: true,
        message: nil,
        duration_us: 100
      }

      assert result.test_name == "test name"
      assert result.passed == true
      assert result.message == nil
      assert result.duration_us == 100
    end

    test "message contains error details for failed tests" do
      result = %Result{
        test_name: "failed test",
        passed: false,
        message: "Expected actor to be able to...",
        duration_us: 50
      }

      assert result.passed == false
      assert is_binary(result.message)
    end
  end
end

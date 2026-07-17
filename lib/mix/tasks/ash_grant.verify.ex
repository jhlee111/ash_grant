defmodule Mix.Tasks.AshGrant.Verify do
  @moduledoc """
  Runs policy configuration tests.

  ## Usage

      # Run all policy tests in default location
      mix ash_grant.verify

      # Run tests from specific directory
      mix ash_grant.verify test/policy_tests/

      # Run tests from a YAML file
      mix ash_grant.verify priv/policy_tests/document.yaml

      # Run with verbose output
      mix ash_grant.verify --verbose

  ## Options

    * `--verbose` - Show detailed output for each test
    * `--format` - Output format: text (default), json

  ## Permission syntax warnings

  After running the tests, this task resolves each policy test actor's permissions and
  reports deprecated or dead grant syntax — see `AshGrant.Permission.diagnostics/1` for
  the full list of codes.

  This only sees grants held by the actors your policy tests declare, so a clean run is
  **not** proof that your permission store is clean. Permission strings live in your own
  database or seeds, which AshGrant cannot reach; to audit all of them, run
  `AshGrant.Permission.diagnostics/1` over your own data:

      MyApp.Role
      |> MyApp.Repo.all()
      |> Enum.flat_map(& &1.permissions)
      |> Enum.flat_map(&AshGrant.Permission.diagnostics/1)

  YAML tests carry their permissions inline rather than through policy test modules and
  are not scanned. Warnings never affect the exit code.

  ## Exit Codes

    * 0 - All tests passed
    * 1 - One or more tests failed
  """

  use Mix.Task

  @shortdoc "Run policy configuration tests"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, args, _} = OptionParser.parse(args, switches: [verbose: :boolean, format: :string])

    verbose = Keyword.get(opts, :verbose, false)
    format = Keyword.get(opts, :format, "text")

    {results, modules} = run_tests(args, verbose)

    output_results(results, format, verbose)

    if format != "json" do
      modules
      |> collect_diagnostics()
      |> print_diagnostics()
    end

    if results.failed > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp run_tests([], verbose) do
    # Default: discover policy test modules
    if verbose, do: Mix.shell().info("Discovering policy test modules...")

    modules = discover_modules()

    if modules == [] do
      Mix.shell().info("No policy test modules found.")
      {%{passed: 0, failed: 0, results: []}, []}
    else
      if verbose do
        Mix.shell().info("Found #{length(modules)} module(s)")
      end

      {AshGrant.PolicyTest.Runner.run_all(modules: modules), modules}
    end
  end

  defp run_tests([path | _], verbose) do
    cond do
      String.ends_with?(path, ".yaml") or String.ends_with?(path, ".yml") ->
        run_yaml_tests(path, verbose)

      File.dir?(path) ->
        run_directory_tests(path, verbose)

      String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs") ->
        run_file_tests(path, verbose)

      true ->
        Mix.shell().error("Unknown path type: #{path}")
        %{passed: 0, failed: 0, results: []}
    end
  end

  defp run_yaml_tests(path, verbose) do
    if verbose, do: Mix.shell().info("Running YAML tests from: #{path}")

    case AshGrant.PolicyTest.YamlParser.run_yaml_tests(path) do
      {:ok, results} ->
        passed = Enum.count(results, & &1.passed)
        failed = Enum.count(results, &(not &1.passed))
        # YAML tests carry their permissions inline rather than through policy test
        # modules, so there are no actors to resolve for the diagnostics pass.
        {%{passed: passed, failed: failed, results: results}, []}

      {:error, reason} ->
        Mix.shell().error("Failed to parse YAML: #{inspect(reason)}")
        {%{passed: 0, failed: 0, results: []}, []}
    end
  end

  defp run_directory_tests(path, verbose) do
    if verbose, do: Mix.shell().info("Running tests from directory: #{path}")

    modules = AshGrant.PolicyTest.Runner.discover_modules(path)

    if modules == [] do
      Mix.shell().info("No policy test modules found in #{path}")
      {%{passed: 0, failed: 0, results: []}, []}
    else
      {AshGrant.PolicyTest.Runner.run_all(modules: modules), modules}
    end
  end

  defp run_file_tests(path, verbose) do
    if verbose, do: Mix.shell().info("Running tests from file: #{path}")

    # Compile the file and find policy test modules
    Code.compile_file(path)

    modules = AshGrant.PolicyTest.Runner.discover_modules(Path.dirname(path))

    if modules == [] do
      Mix.shell().info("No policy test modules found in #{path}")
      {%{passed: 0, failed: 0, results: []}, []}
    else
      {AshGrant.PolicyTest.Runner.run_all(modules: modules), modules}
    end
  end

  defp discover_modules do
    # Look in common locations
    paths = ["test/policy_tests", "priv/policy_tests"]

    paths
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&AshGrant.PolicyTest.Runner.discover_modules/1)
  end

  defp output_results(results, "json", _verbose) do
    json =
      %{
        passed: results.passed,
        failed: results.failed,
        tests:
          Enum.map(results.results, fn r ->
            %{
              name: r.test_name,
              passed: r.passed,
              message: r.message,
              duration_us: r.duration_us
            }
          end)
      }
      |> Jason.encode!(pretty: true)

    Mix.shell().info(json)
  end

  defp output_results(results, _format, verbose) do
    if verbose do
      Enum.each(results.results, &print_verbose_result/1)
      Mix.shell().info("")
    end

    print_summary(results)
  end

  defp print_verbose_result(%{passed: true, test_name: name}) do
    Mix.shell().info("  ✓ #{name}")
  end

  defp print_verbose_result(%{passed: false, test_name: name, message: message}) do
    Mix.shell().error("  ✗ #{name}")
    Mix.shell().error("    #{message}")
  end

  # Resolves each policy test module's actors through the real resolver and reports any
  # permission syntax problems in the grants that come back. This only sees grants that
  # the declared test actors happen to hold — it is not an audit of your whole permission
  # store. To check that, run `AshGrant.Permission.diagnostics/1` over your own data.
  defp collect_diagnostics(modules) do
    modules
    |> Enum.flat_map(&module_diagnostics/1)
    |> Enum.uniq_by(&{&1.code, &1.permission})
    |> Enum.sort_by(&{&1.permission, &1.code})
  end

  defp module_diagnostics(module) do
    if function_exported?(module, :__policy_test__, 1) do
      case module.__policy_test__(:resource) do
        nil -> []
        resource -> actor_diagnostics(module, resource)
      end
    else
      []
    end
  end

  defp actor_diagnostics(module, resource) do
    module.__policy_test__(:actors)
    |> Enum.flat_map(fn {_name, attrs} ->
      resource
      |> AshGrant.Introspect.permissions_for(attrs)
      |> Enum.flat_map(&AshGrant.Permission.diagnostics/1)
    end)
  rescue
    # A resolver that cannot handle a bare actor map is the policy tests' problem to
    # report, not the diagnostics pass's — stay quiet rather than break the run.
    _ -> []
  end

  defp print_diagnostics([]), do: :ok

  defp print_diagnostics(diagnostics) do
    count = length(diagnostics)
    noun = if count == 1, do: "warning", else: "warnings"

    Mix.shell().info("")
    Mix.shell().info("#{count} permission syntax #{noun}:")

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().info("")
      Mix.shell().info("  #{diagnostic.permission}")
      Mix.shell().info("    #{diagnostic.message}")

      if diagnostic.suggestion do
        Mix.shell().info("    Replace with: #{diagnostic.suggestion}")
      end
    end)

    Mix.shell().info("")
  end

  defp print_summary(%{failed: 0, passed: passed}) do
    Mix.shell().info("#{passed} test(s) passed")
  end

  defp print_summary(%{failed: failed, passed: passed}) do
    total = passed + failed
    Mix.shell().error("#{failed}/#{total} test(s) failed")
  end
end

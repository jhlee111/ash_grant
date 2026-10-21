defmodule Mix.Tasks.AshGrant.Verify do
  @moduledoc """
  Runs policy configuration tests.

  ## Usage

      # Run all policy tests in the default locations
      mix ash_grant.verify

      # Run every policy test under a directory
      mix ash_grant.verify test/policy_tests/

      # Run one file, or several paths
      mix ash_grant.verify priv/policy_tests/document.yaml
      mix ash_grant.verify test/policy_tests/post_test.exs priv/policy_tests/document.yaml

      # Run with verbose output
      mix ash_grant.verify --verbose

  Each path is a directory or a single file:

    * a directory runs every policy test module in its `.ex` and `.exs` files and
      every `.yaml`/`.yml` file, recursively;
    * an `.ex` or `.exs` file runs only the policy test modules that file defines;
    * a `.yaml` or `.yml` file runs that file's tests.

  Without a path, `test/policy_tests` and `priv/policy_tests` are searched the same
  way. Files Mix does not compile — any `.exs`, or an `.ex` outside `elixirc_paths`
  such as one in `priv/` — are compiled by the task.

  ## Options

    * `--verbose` - List every test, not only the failures
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

  `diagnostics/1` reports spelling only. To also check that each stored string names a
  resource, action, scope and field group that exist, use
  `mix ash_grant.check_permissions` (or `AshGrant.PermissionValidation.check_all/2`).

  YAML tests carry their permissions inline rather than through policy test modules and
  are not scanned. Warnings never affect the exit code.

  ## Exit Codes

    * 0 - All tests passed. Also when no path is given and the default locations
      hold no policy tests.
    * 1 - One or more tests failed.
    * 2 - The run is incomplete: a path does not exist or is not a policy test file,
      a file does not compile, a YAML file does not parse or defines no tests, a
      path given holds no policy tests, or an option is invalid. Tests that could
      run still run and are reported; 2 takes precedence over 1.
  """

  use Mix.Task

  alias AshGrant.PolicyTest.{Runner, YamlParser}

  @shortdoc "Run policy configuration tests"

  @switches [verbose: :boolean, format: :string]

  @default_paths ["test/policy_tests", "priv/policy_tests"]

  @empty_run %{results: [], modules: [], errors: []}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case run_cli(args) do
      {:ok, output, 0} ->
        Mix.shell().info(output)

      {:error, output, exit_code} ->
        Mix.shell().error(output)
        System.at_exit(fn _ -> exit({:shutdown, exit_code}) end)
    end
  end

  @doc """
  Pure entry point used by both `run/1` and the test suite.

  Returns `{:ok | :error, output_string, exit_code}` so callers can
  inspect the task's behaviour without intercepting Mix shell output.
  """
  @spec run_cli([String.t()]) :: {:ok, String.t(), 0} | {:error, String.t(), 1 | 2}
  def run_cli(args) do
    with {:ok, opts, paths} <- parse_args(args),
         {:ok, format} <- parse_format(opts) do
      verbose = Keyword.get(opts, :verbose, false)

      case run_paths(paths) do
        :none_found ->
          {:ok, "No policy tests found in #{Enum.join(@default_paths, " or ")}.", 0}

        run ->
          report(run, format, verbose)
      end
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, paths, []} ->
        {:ok, opts, paths}

      {_opts, _paths, invalid} ->
        {:error, "Invalid options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}", 2}
    end
  end

  defp parse_format(opts) do
    case Keyword.get(opts, :format, "text") do
      "text" -> {:ok, :text}
      "json" -> {:ok, :json}
      other -> {:error, "Invalid --format: #{other} (expected text or json)", 2}
    end
  end

  # -- running ----------------------------------------------------------------

  # The default locations are optional — a project without policy tests is not an
  # error. A path the caller names is expected to hold some.
  defp run_paths([]) do
    case @default_paths |> Enum.filter(&File.dir?/1) |> Enum.map(&run_path/1) |> merge() do
      %{results: [], errors: []} -> :none_found
      run -> run
    end
  end

  defp run_paths(paths) do
    paths
    |> Enum.map(fn path ->
      case run_path(path) do
        %{results: [], errors: []} -> load_error(path, "no policy tests found")
        run -> run
      end
    end)
    |> merge()
  end

  defp run_path(path) do
    cond do
      not File.exists?(path) ->
        load_error(path, "no such file or directory")

      File.dir?(path) ->
        yaml_files = path |> Path.join("**/*.{yaml,yml}") |> Path.wildcard()
        merge([run_modules(path) | Enum.map(yaml_files, &run_yaml/1)])

      Path.extname(path) in [".yaml", ".yml"] ->
        run_yaml(path)

      Path.extname(path) in [".ex", ".exs"] ->
        run_modules(path)

      true ->
        load_error(
          path,
          "not a policy test file (expected a directory, .ex, .exs, .yaml or .yml)"
        )
    end
  end

  defp run_modules(path) do
    modules = Runner.discover_modules(path)
    %{results: results} = Runner.run_all(modules: modules)
    %{@empty_run | results: results, modules: modules}
  rescue
    # Discovery compiles the files Mix does not; a file that does not compile is
    # a run that did not happen, not a pass.
    error -> load_error(path, Exception.message(error))
  end

  defp run_yaml(path) do
    case YamlParser.run_yaml_tests(path) do
      {:ok, []} ->
        load_error(path, "defines no tests (expected a top-level `tests:` list)")

      {:ok, results} ->
        %{@empty_run | results: results}

      {:error, reason} ->
        load_error(path, yaml_error(reason))
    end
  rescue
    error -> load_error(path, Exception.message(error))
  end

  defp yaml_error(:yaml_elixir_not_available),
    do: "YAML policy tests need the optional :yaml_elixir dependency"

  defp yaml_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp yaml_error(reason), do: inspect(reason)

  defp load_error(path, message), do: %{@empty_run | errors: [%{path: path, message: message}]}

  defp merge(runs) do
    Enum.reduce(runs, @empty_run, fn run, acc ->
      %{
        results: acc.results ++ run.results,
        modules: acc.modules ++ run.modules,
        errors: acc.errors ++ run.errors
      }
    end)
  end

  # -- output -----------------------------------------------------------------

  defp report(run, format, verbose) do
    failed = Enum.count(run.results, &(not &1.passed))
    output = render(run, failed, format, verbose)

    cond do
      run.errors != [] -> {:error, output, 2}
      failed > 0 -> {:error, output, 1}
      true -> {:ok, output, 0}
    end
  end

  defp render(run, failed, :json, _verbose) do
    Jason.encode!(
      %{
        passed: length(run.results) - failed,
        failed: failed,
        tests:
          Enum.map(run.results, fn r ->
            %{
              name: r.test_name,
              passed: r.passed,
              message: r.message,
              duration_us: r.duration_us
            }
          end),
        errors: run.errors
      },
      pretty: true
    )
  end

  defp render(run, failed, :text, verbose) do
    listed = if verbose, do: run.results, else: Enum.reject(run.results, & &1.passed)

    [
      Enum.map(listed, &format_result/1),
      Enum.map(run.errors, &"error: #{&1.path}: #{&1.message}"),
      [summary(length(run.results) - failed, failed, length(run.errors))],
      run.modules |> collect_diagnostics() |> format_diagnostics()
    ]
    |> Enum.reject(&(&1 == []))
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
  end

  defp format_result(%{passed: true, test_name: name}), do: "  ✓ #{name}"

  defp format_result(%{passed: false, test_name: name, message: message}),
    do: "  ✗ #{name}\n    #{message}"

  defp summary(passed, 0, errors), do: "#{passed} test(s) passed" <> errors_suffix(errors)

  defp summary(passed, failed, errors),
    do: "#{failed}/#{passed + failed} test(s) failed" <> errors_suffix(errors)

  defp errors_suffix(0), do: ""
  defp errors_suffix(errors), do: ", #{errors} error(s)"

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

  defp format_diagnostics([]), do: []

  defp format_diagnostics(diagnostics) do
    count = length(diagnostics)
    noun = if count == 1, do: "warning", else: "warnings"

    lines =
      Enum.flat_map(diagnostics, fn diagnostic ->
        suggestion =
          if diagnostic.suggestion, do: ["    Replace with: #{diagnostic.suggestion}"], else: []

        ["", "  #{diagnostic.permission}", "    #{diagnostic.message}" | suggestion]
      end)

    ["#{count} permission syntax #{noun}:" | lines]
  end
end

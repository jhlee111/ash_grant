defmodule AshGrant.PolicyTest.Runner do
  @moduledoc """
  Executes policy tests and collects results.

  The runner provides two main functions:

  - `run_module/1` - Run all tests in a single module
  - `run_all/1` - Run tests across multiple modules with summary statistics

  ## Examples

      # Run a single module
      results = Runner.run_module(MyApp.PolicyTests.DocumentTest)

      # Run multiple modules
      summary = Runner.run_all(modules: [DocumentTest, PostTest])

      # Run with discovery (finds all policy test modules)
      summary = Runner.run_all(path: "test/policy_tests/")
  """

  alias AshGrant.PolicyTest.Result

  @type summary :: %{
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          results: [Result.t()]
        }

  @doc """
  Runs all tests in a policy test module.

  Returns a list of `Result` structs, one for each test.

  ## Examples

      results = Runner.run_module(MyApp.PolicyTests.DocumentTest)

      Enum.each(results, fn result ->
        if result.passed do
          IO.puts("✓ \#{result.test_name}")
        else
          IO.puts("✗ \#{result.test_name}: \#{result.message}")
        end
      end)
  """
  @spec run_module(module()) :: [Result.t()]
  def run_module(module) do
    tests = module.__policy_test__(:tests)
    context = module.__policy_test__(:context)

    Enum.map(tests, fn test_def ->
      run_single_test(test_def, context)
    end)
  end

  @doc """
  Runs tests across multiple modules and returns a summary.

  ## Options

  - `:modules` - List of modules to run tests from
  - `:path` - Path to directory containing policy test files (discovers modules)

  ## Examples

      # Run specific modules
      summary = Runner.run_all(modules: [DocumentTest, PostTest])

      # Discover and run all policy tests in a directory
      summary = Runner.run_all(path: "test/policy_tests/")

  ## Returns

      %{
        passed: 10,
        failed: 2,
        results: [%Result{}, ...]
      }
  """
  @spec run_all(keyword()) :: summary()
  def run_all(opts) do
    modules = get_modules(opts)

    all_results =
      Enum.flat_map(modules, fn module ->
        module
        |> run_module()
        |> Enum.map(&Map.put(&1, :module, module))
      end)

    passed = Enum.count(all_results, & &1.passed)
    failed = Enum.count(all_results, &(not &1.passed))

    %{
      passed: passed,
      failed: failed,
      results: all_results
    }
  end

  @doc """
  Discovers policy test modules from a path.

  `path` is a directory, searched recursively for `.ex` and `.exs` files, or a
  single such file. Only files that `use AshGrant.PolicyTest` are considered, and
  only the policy test modules they define are returned — a helper module in the
  same file is not.

  A file that is already compiled into the running application (under
  `elixirc_paths`) is used as loaded. Any other file — an `.exs`, or an `.ex` in a
  directory Mix does not compile, such as `priv/` — is compiled here, so a file
  that does not compile raises.
  """
  @spec discover_modules(String.t()) :: [module()]
  def discover_modules(path) do
    path
    |> source_files()
    |> Enum.flat_map(&find_policy_test_modules/1)
  end

  # Private functions

  defp run_single_test(test_def, context) do
    test_name = test_def.name
    start_time = System.monotonic_time(:microsecond)

    try do
      test_def.fun.(context)
      duration = System.monotonic_time(:microsecond) - start_time
      Result.pass(test_name, duration)
    rescue
      e in AshGrant.PolicyTest.AssertionError ->
        duration = System.monotonic_time(:microsecond) - start_time
        Result.fail(test_name, e.message, duration)

      e ->
        duration = System.monotonic_time(:microsecond) - start_time
        message = "Unexpected error: #{Exception.message(e)}"
        Result.fail(test_name, message, duration)
    end
  end

  defp get_modules(opts) do
    cond do
      Keyword.has_key?(opts, :modules) ->
        Keyword.fetch!(opts, :modules)

      Keyword.has_key?(opts, :path) ->
        discover_modules(Keyword.fetch!(opts, :path))

      true ->
        raise ArgumentError, "Either :modules or :path option is required"
    end
  end

  defp source_files(path) do
    if File.dir?(path) do
      path |> Path.join("**/*.{ex,exs}") |> Path.wildcard()
    else
      [path]
    end
  end

  defp find_policy_test_modules(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        if String.contains?(content, "use AshGrant.PolicyTest") do
          file_path
          |> load_modules(content)
          |> Enum.filter(&policy_test_module?/1)
        else
          []
        end

      {:error, _} ->
        []
    end
  end

  defp load_modules(file_path, content) do
    case compiled_modules(content) do
      {:ok, modules} -> modules
      :error -> file_path |> Code.compile_file() |> Enum.map(&elem(&1, 0))
    end
  end

  # The modules the file declares, when every one of them is already loadable —
  # compiling the file again would redefine them under the running application.
  # Anything that cannot be named statically sends the file to the compiler, which
  # reports exactly what the file defines.
  defp compiled_modules(content) do
    with {:ok, ast} <- Code.string_to_quoted(content),
         {_ast, {[], names}} <- Macro.traverse(ast, {[], []}, &enter_module/2, &leave_module/2),
         false <- names == [] or :unknown in names,
         modules = Enum.map(names, &safe_concat/1),
         true <- Enum.all?(modules, &(&1 && Code.ensure_loaded?(&1))) do
      {:ok, Enum.reverse(modules)}
    else
      _ -> :error
    end
  end

  # A nested `defmodule` is named relative to its parent, unless it is spelled
  # `Elixir.Name`. The stack holds the alias segments of each enclosing module.
  defp enter_module({:defmodule, _, [{:__aliases__, _, parts} | _]} = node, {stack, names}) do
    name =
      case {parts, stack} do
        {[Elixir | _], _} -> parts
        {_, [:unknown | _]} -> :unknown
        {_, [parent | _]} -> parent ++ parts
        {_, []} -> parts
      end

    name = if name != :unknown and Enum.all?(name, &is_atom/1), do: name, else: :unknown
    {node, {[name | stack], [name | names]}}
  end

  defp enter_module({:defmodule, _, _} = node, {stack, names}),
    do: {node, {[:unknown | stack], [:unknown | names]}}

  defp enter_module(node, acc), do: {node, acc}

  defp leave_module({:defmodule, _, _} = node, {[_ | stack], names}), do: {node, {stack, names}}
  defp leave_module(node, acc), do: {node, acc}

  # Never creates an atom: a module whose name is not an atom yet is not loaded.
  defp safe_concat(parts) do
    Module.safe_concat(parts)
  rescue
    ArgumentError -> nil
  end

  defp policy_test_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__policy_test__, 1)
  end
end

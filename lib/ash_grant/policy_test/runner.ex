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
        |> run_module_safely()
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
  same file is not. A file that also `use`s `ExUnit.Case` is an ExUnit test, run by
  `mix test`, and is skipped.

  A file that is already compiled into the running application (under
  `elixirc_paths`) is used as loaded. Any other file — an `.exs`, or an `.ex` in a
  directory Mix does not compile, such as `priv/` — is compiled here, on every call,
  so an edited file is picked up and a file that does not compile raises.
  """
  @spec discover_modules(String.t()) :: [module()]
  def discover_modules(path) do
    path
    |> source_files()
    |> Enum.flat_map(&find_policy_test_modules/1)
  end

  # Private functions

  # A module whose tests cannot even be listed (its `context` raises, say) is one
  # failed result, so the other modules' results are still reported.
  defp run_module_safely(module) do
    run_module(module)
  rescue
    e -> [Result.fail(inspect(module), "Unexpected error: #{Exception.message(e)}", 0)]
  end

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

  # A file that does not parse is compiled anyway, so its syntax error surfaces.
  defp load_modules(file_path, content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} -> load_parsed_modules(file_path, scan(ast))
      {:error, _} -> compile(file_path)
    end
  end

  # Only a file that really uses `AshGrant.PolicyTest` is loaded — not one that
  # merely mentions it in a comment or a string — and never an ExUnit test file,
  # which `mix test` runs and which cannot be compiled outside of it.
  defp load_parsed_modules(_file_path, %{policy_test?: false}), do: []
  defp load_parsed_modules(_file_path, %{ex_unit?: true}), do: []

  defp load_parsed_modules(file_path, %{names: names}) do
    case compiled_modules(file_path, names) do
      {:ok, modules} -> modules
      :error -> compile(file_path)
    end
  end

  defp compile(file_path), do: file_path |> Code.compile_file() |> Enum.map(&elem(&1, 0))

  # The modules the file declares, when every one of them was compiled from this
  # file into the running application (a `.beam` on disk, as Mix builds it) —
  # compiling the file again would redefine them. A module loaded any other way,
  # such as by an earlier discovery of the same file, may be stale, and one from
  # another file is not this file's; anything that cannot be named statically
  # sends the file to the compiler, which reports exactly what the file defines.
  defp compiled_modules(file_path, names) do
    source = file_path |> Path.expand() |> String.to_charlist()

    with false <- names == [] or :unknown in names,
         modules = Enum.map(names, &safe_concat/1),
         true <- Enum.all?(modules, &(&1 && compiled_from?(&1, source))) do
      {:ok, Enum.reverse(modules)}
    else
      _ -> :error
    end
  end

  defp compiled_from?(module, source) do
    Code.ensure_loaded?(module) and match?([_ | _], :code.which(module)) and
      module.module_info(:compile)[:source] == source
  end

  defp scan(ast) do
    acc = %{stack: [], names: [], policy_test?: false, ex_unit?: false}
    {_ast, acc} = Macro.traverse(ast, acc, &enter_module/2, &leave_module/2)
    acc
  end

  # A nested `defmodule` is named relative to its parent, unless it is spelled
  # `Elixir.Name`. The stack holds the alias segments of each enclosing module.
  # Code inside `quote` is not defined by compiling the file, so it is skipped.
  defp enter_module({:quote, _, _}, acc), do: {:__skipped_quote__, acc}

  defp enter_module({:use, _, [{:__aliases__, _, [:AshGrant, :PolicyTest]} | _]} = node, acc),
    do: {node, %{acc | policy_test?: true}}

  defp enter_module({:use, _, [{:__aliases__, _, [:ExUnit, :Case]} | _]} = node, acc),
    do: {node, %{acc | ex_unit?: true}}

  defp enter_module({:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc) do
    name =
      case {parts, acc.stack} do
        {[Elixir | _], _} -> parts
        {_, [:unknown | _]} -> :unknown
        {_, [parent | _]} -> parent ++ parts
        {_, []} -> parts
      end

    name = if name != :unknown and Enum.all?(name, &is_atom/1), do: name, else: :unknown
    {node, %{acc | stack: [name | acc.stack], names: [name | acc.names]}}
  end

  defp enter_module({:defmodule, _, _} = node, acc),
    do: {node, %{acc | stack: [:unknown | acc.stack], names: [:unknown | acc.names]}}

  defp enter_module(node, acc), do: {node, acc}

  defp leave_module({:defmodule, _, _} = node, %{stack: [_ | stack]} = acc),
    do: {node, %{acc | stack: stack}}

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

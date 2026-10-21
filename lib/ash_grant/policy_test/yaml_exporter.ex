defmodule AshGrant.PolicyTest.YamlExporter do
  @moduledoc """
  Exports a policy test module to the YAML format `AshGrant.PolicyTest.YamlParser`
  reads, for sharing tests with people who do not write Elixir.

  The export tests exactly what the module tests, or it is refused:

    * Each test body must be one or more assertion calls — `assert_can`,
      `assert_cannot`, `assert_fields_visible`, `assert_fields_hidden` — whose
      arguments are literals.
    * A YAML test holds one assertion, so a test with several becomes several
      YAML tests, numbered `name (1/3)`, `name (2/3)`, … The suite passes only
      when all of them do, as the DSL test does.
    * YAML has no atom type. Atoms are written as strings, and the YAML parser
      reads identifier-like strings (`draft`, `read_all`) back as atoms.

  Anything else — a body that computes its arguments (a variable, a helper call,
  a loop), a test with no assertion, a value YAML cannot carry back unchanged (a
  struct, a tuple, a nested map, an atom such as `:Draft` that would read back as
  a string), an actor that is not a map — raises `ArgumentError` naming every
  such test and actor.

  ## Examples

      yaml = YamlExporter.export(MyApp.PolicyTests.DocumentTest)
      File.write!("document_tests.yaml", yaml)
  """

  @assertions [:assert_can, :assert_cannot, :assert_fields_visible, :assert_fields_hidden]

  # Mirrors YamlParser's atomize_value/1: only these strings are read back as atoms.
  @atom_like ~r/^[a-z_][a-z0-9_]*$/

  @doc """
  Exports a policy test module to YAML format.

  Raises `ArgumentError` when the module holds a test or actor YAML cannot
  express faithfully; see the module documentation.
  """
  @spec export(module()) :: String.t()
  def export(module) do
    # Sorted: the actors come back as a map, whose iteration order is not stable.
    actors =
      module.__policy_test__(:actors)
      |> Enum.sort_by(fn {name, _attrs} -> Atom.to_string(name) end)
      |> Enum.map(&export_actor/1)

    tests = Enum.map(module.__policy_test__(:tests), &export_test/1)

    case for({:error, problem} <- actors ++ tests, do: problem) do
      [] ->
        render(
          {:map,
           [
             {"resource", inspect(module.__policy_test__(:resource))},
             {"actors", {:map, for({:ok, actor} <- actors, do: actor)}},
             {"tests", Enum.flat_map(tests, fn {:ok, yaml_tests} -> yaml_tests end)}
           ]}
        )

      problems ->
        raise ArgumentError,
              "cannot export #{inspect(module)} to YAML without changing what it tests:\n" <>
                Enum.map_join(problems, "\n", &"  * #{&1}")
    end
  end

  # -- actors and tests -------------------------------------------------------

  defp export_actor({name, attrs}) when is_map(attrs) do
    case mapping(attrs) do
      {:ok, node} -> {:ok, {Atom.to_string(name), node}}
      {:error, reason} -> {:error, "actor :#{name}: #{reason}"}
    end
  end

  defp export_actor({name, attrs}) do
    {:error, "actor :#{name} is #{inspect(attrs)}; a YAML actor is a map of attributes"}
  end

  defp export_test(%{name: name, body: body}) do
    calls =
      case body do
        {:__block__, _, exprs} -> exprs
        expr -> [expr]
      end

    results = Enum.map(calls, &export_assertion/1)

    case for({:error, reason} <- results, do: reason) do
      [] -> {:ok, number(name, for({:ok, assertion} <- results, do: assertion))}
      [reason | _] -> {:error, "test #{inspect(name)}: #{reason}"}
    end
  end

  defp number(name, [assertion]), do: [yaml_test(name, assertion)]

  defp number(name, assertions) do
    count = length(assertions)

    for {assertion, i} <- Enum.with_index(assertions, 1),
        do: yaml_test("#{name} (#{i}/#{count})", assertion)
  end

  defp yaml_test(name, {kind, body}), do: {:map, [{"name", name}, {kind, body}]}

  defp export_assertion({kind, _, args} = call) when kind in @assertions and is_list(args) do
    if Enum.all?(args, &Macro.quoted_literal?/1) do
      assertion(kind, Enum.map(args, &literal/1))
    else
      {:error, "`#{Macro.to_string(call)}` computes its arguments; only literals can be exported"}
    end
  end

  defp export_assertion(expr) do
    {:error, "`#{Macro.to_string(expr)}` is not an assertion"}
  end

  # Quoted literals only (checked by the caller), so this never evaluates code.
  # Aliases and structs are literals to the compiler but not values here; they
  # come back as their AST and are refused by `yaml_value/1`.
  defp literal({:%{}, _, pairs}), do: Map.new(pairs, fn {k, v} -> {literal(k), literal(v)} end)
  defp literal({:{}, _, elems}), do: elems |> Enum.map(&literal/1) |> List.to_tuple()
  defp literal({left, right}), do: {literal(left), literal(right)}
  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal(other), do: other

  defp assertion(kind, [actor, spec | target])
       when kind in [:assert_can, :assert_cannot] and is_atom(actor) do
    with {:ok, action} <- action(spec),
         {:ok, target} <- target(target) do
      {:ok, {Atom.to_string(kind), {:map, [{"actor", Atom.to_string(actor)} | action ++ target]}}}
    end
  end

  defp assertion(kind, [actor, spec, fields]) when is_atom(actor) and is_list(fields) do
    with {:ok, [{"action", _}] = action} <- action(spec),
         true <- Enum.all?(fields, &is_atom/1) do
      fields = Enum.map(fields, &Atom.to_string/1)

      {:ok,
       {Atom.to_string(kind),
        {:map, [{"actor", Atom.to_string(actor)} | action] ++ [{"fields", fields}]}}}
    else
      {:ok, _action_type} -> {:error, "#{kind} takes an action, not an action_type"}
      false -> {:error, "#{kind} fields must be atoms, got #{inspect(fields)}"}
      error -> error
    end
  end

  defp assertion(kind, args), do: {:error, "#{kind} with #{inspect(args)} has no YAML form"}

  defp action(action) when is_atom(action), do: {:ok, [{"action", Atom.to_string(action)}]}
  defp action(action: action) when is_atom(action), do: action(action)

  defp action(action_type: type) when is_atom(type),
    do: {:ok, [{"action_type", Atom.to_string(type)}]}

  defp action(spec), do: {:error, "action #{inspect(spec)} has no YAML form"}

  # The DSL's third argument: nothing, a bare record map, or
  # `[record: ..., arguments: ...]`.
  defp target([]), do: {:ok, []}
  defp target([nil]), do: {:ok, []}
  defp target([record]) when is_map(record), do: target([[record: record]])

  defp target([opts]) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:record, :arguments] == [] do
      with {:ok, record} <- target_map("record", opts[:record]),
           {:ok, arguments} <- target_map("arguments", opts[:arguments]) do
        {:ok, record ++ arguments}
      end
    else
      invalid_target()
    end
  end

  defp target(_other), do: invalid_target()

  defp invalid_target,
    do: {:error, "the third argument is neither a record nor [record: ..., arguments: ...]"}

  defp target_map(_key, empty) when empty in [nil, %{}], do: {:ok, []}

  defp target_map(key, map) when is_map(map) do
    case mapping(map) do
      {:ok, node} -> {:ok, [{key, node}]}
      {:error, reason} -> {:error, "#{key}: #{reason}"}
    end
  end

  defp target_map(key, other), do: {:error, "#{key} #{inspect(other)} is not a map"}

  # -- values -----------------------------------------------------------------

  # A record, arguments or actor map. The parser atomizes its keys but leaves a
  # nested map's keys as strings, so values may be scalars and lists only.
  defp mapping(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      with true <- is_atom(key) or {:error, "key #{inspect(key)} would read back as an atom"},
           {:ok, node} <- yaml_value(value) do
        {:cont, {:ok, acc ++ [{Atom.to_string(key), node}]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, {:map, pairs}}
      error -> error
    end
  end

  defp yaml_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp yaml_value(atom) when is_atom(atom) do
    string = Atom.to_string(atom)

    if string =~ @atom_like,
      do: {:ok, string},
      else: {:error, "#{inspect(atom)} would read back as the string #{inspect(string)}"}
  end

  defp yaml_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case yaml_value(value) do
        {:ok, node} -> {:cont, {:ok, acc ++ [node]}}
        error -> {:halt, error}
      end
    end)
  end

  defp yaml_value(map) when is_map(map) and not is_struct(map),
    do: {:error, "nested map #{inspect(map)} would read back with string keys"}

  defp yaml_value(other), do: {:error, "#{inspect(other)} has no YAML form"}

  # -- rendering --------------------------------------------------------------

  # Block-style YAML from `{:map, [{key, node}]}`, lists and scalars. Strings are
  # written as JSON strings, which are valid YAML double-quoted scalars, so quotes,
  # colons and leading symbols survive.
  defp render(node), do: node |> lines() |> Enum.join("\n") |> Kernel.<>("\n")

  defp lines({:map, pairs}) do
    Enum.flat_map(pairs, fn
      {key, {:map, []}} -> ["#{key(key)}: {}"]
      {key, []} -> ["#{key(key)}: []"]
      {key, {:map, _} = map} -> ["#{key(key)}:" | indent(lines(map))]
      {key, list} when is_list(list) -> ["#{key(key)}:" | indent(Enum.flat_map(list, &item/1))]
      {key, scalar} -> ["#{key(key)}: #{scalar(scalar)}"]
    end)
  end

  defp item(node) do
    [first | rest] =
      case node do
        {:map, _} -> lines(node)
        scalar -> [scalar(scalar)]
      end

    ["- " <> first | Enum.map(rest, &("  " <> &1))]
  end

  defp indent(lines), do: Enum.map(lines, &("  " <> &1))

  defp key(key), do: if(key =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/, do: key, else: Jason.encode!(key))

  defp scalar(nil), do: "null"
  defp scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp scalar(value) when is_binary(value), do: Jason.encode!(value)
end

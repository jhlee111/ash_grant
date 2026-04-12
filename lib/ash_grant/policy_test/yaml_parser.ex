defmodule AshGrant.PolicyTest.YamlParser do
  @moduledoc """
  Parses YAML policy test files and runs them.

  YAML provides an alternative format for defining policy tests,
  useful for:

  - Non-Elixir developers reviewing permissions
  - Generating tests from external tools
  - Documentation purposes

  ## YAML Format

      resource: MyApp.Document

      actors:
        reader:
          role: reader
        author:
          role: author
          id: "author_001"

      tests:
        - name: "reader can read"
          assert_can:
            actor: reader
            action: read

        - name: "reader can read published"
          assert_can:
            actor: reader
            action: read
            record:
              status: published

        - name: "reader cannot read drafts"
          assert_cannot:
            actor: reader
            action: read
            record:
              status: draft

  ## Usage

      # Parse YAML file
      {:ok, parsed} = YamlParser.parse_file("policy_tests/document.yaml")

      # Run tests from YAML file
      {:ok, results} = YamlParser.run_yaml_tests("policy_tests/document.yaml")
  """

  alias AshGrant.PolicyTest.{Assertions, Result}

  @type parsed_test :: %{
          name: String.t(),
          type: :assert_can | :assert_cannot | :assert_fields_visible | :assert_fields_hidden,
          actor: atom(),
          action: atom() | nil,
          action_type: atom() | nil,
          record: map() | nil,
          fields: [atom()] | nil
        }

  @type parsed :: %{
          resource: module(),
          actors: %{atom() => map()},
          tests: [parsed_test()]
        }

  @doc """
  Parses a YAML policy test file.

  Returns `{:ok, parsed}` on success or `{:error, reason}` on failure.
  """
  @spec parse_file(String.t()) :: {:ok, parsed()} | {:error, term()}
  def parse_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, yaml} <- parse_yaml(content) do
      {:ok, transform(yaml)}
    end
  end

  @doc """
  Parses a YAML policy test file and raises on error.
  """
  @spec parse_file!(String.t()) :: parsed()
  def parse_file!(path) do
    case parse_file(path) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise "Failed to parse YAML file: #{inspect(reason)}"
    end
  end

  @doc """
  Runs tests from a YAML file and returns results.
  """
  @spec run_yaml_tests(String.t()) :: {:ok, [Result.t()]} | {:error, term()}
  def run_yaml_tests(path) do
    case parse_file(path) do
      {:ok, parsed} ->
        results = run_parsed_tests(parsed)
        {:ok, results}

      {:error, _} = error ->
        error
    end
  end

  # Private functions

  defp parse_yaml(content) do
    if Code.ensure_loaded?(YamlElixir) do
      YamlElixir.read_from_string(content)
    else
      {:error, :yaml_elixir_not_available}
    end
  end

  defp transform(yaml) when is_map(yaml) do
    %{
      resource: parse_resource(yaml["resource"]),
      actors: parse_actors(yaml["actors"]),
      tests: parse_tests(yaml["tests"])
    }
  end

  defp parse_resource(resource_str) when is_binary(resource_str) do
    String.to_existing_atom("Elixir." <> resource_str)
  rescue
    ArgumentError -> String.to_atom("Elixir." <> resource_str)
  end

  defp parse_actors(nil), do: %{}

  defp parse_actors(actors) when is_map(actors) do
    actors
    |> Enum.map(fn {name, attrs} ->
      {atomize_key(name), atomize_map(attrs)}
    end)
    |> Enum.into(%{})
  end

  defp parse_tests(nil), do: []

  defp parse_tests(tests) when is_list(tests) do
    Enum.map(tests, &parse_test/1)
  end

  defp parse_test(test) do
    name = test["name"]

    cond do
      Map.has_key?(test, "assert_can") ->
        parse_assertion(:assert_can, name, test["assert_can"])

      Map.has_key?(test, "assert_cannot") ->
        parse_assertion(:assert_cannot, name, test["assert_cannot"])

      Map.has_key?(test, "assert_fields_visible") ->
        parse_field_assertion(:assert_fields_visible, name, test["assert_fields_visible"])

      Map.has_key?(test, "assert_fields_hidden") ->
        parse_field_assertion(:assert_fields_hidden, name, test["assert_fields_hidden"])

      true ->
        raise "Test must have assert_can, assert_cannot, assert_fields_visible, or assert_fields_hidden: #{inspect(test)}"
    end
  end

  defp parse_assertion(type, name, assertion) do
    %{
      name: name,
      type: type,
      actor: atomize_key(assertion["actor"]),
      action: parse_action(assertion["action"]),
      action_type: parse_action(assertion["action_type"]),
      record: parse_record(assertion["record"])
    }
  end

  defp parse_field_assertion(type, name, assertion) do
    fields =
      assertion["fields"]
      |> List.wrap()
      |> Enum.map(&atomize_key/1)

    %{
      name: name,
      type: type,
      actor: atomize_key(assertion["actor"]),
      action: parse_action(assertion["action"]),
      action_type: nil,
      record: nil,
      fields: fields
    }
  end

  defp parse_action(nil), do: nil
  defp parse_action(action) when is_binary(action), do: String.to_atom(action)
  defp parse_action(action) when is_atom(action), do: action

  defp parse_record(nil), do: nil

  defp parse_record(record) when is_map(record) do
    atomize_map(record)
  end

  defp atomize_key(key) when is_binary(key), do: String.to_atom(key)
  defp atomize_key(key) when is_atom(key), do: key

  defp atomize_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      {atomize_key(k), atomize_value(v)}
    end)
    |> Enum.into(%{})
  end

  defp atomize_value(value) when is_binary(value) do
    # Try to convert to atom if it looks like an atom (lowercase, no spaces)
    if Regex.match?(~r/^[a-z_][a-z0-9_]*$/, value) do
      String.to_atom(value)
    else
      value
    end
  end

  defp atomize_value(value) when is_list(value) do
    Enum.map(value, &atomize_value/1)
  end

  defp atomize_value(value), do: value

  # Run parsed tests

  defp run_parsed_tests(parsed) do
    resource = parsed.resource
    actors = parsed.actors

    Enum.map(parsed.tests, fn test ->
      run_single_parsed_test(test, resource, actors)
    end)
  end

  defp run_single_parsed_test(test, resource, actors) do
    start_time = System.monotonic_time(:microsecond)
    actor = Map.get(actors, test.actor)

    action_spec =
      cond do
        test.action_type != nil -> {:action_type, test.action_type}
        test.action != nil -> test.action
        true -> raise "Test must have action or action_type: #{inspect(test)}"
      end

    try do
      case test.type do
        :assert_can ->
          do_assert_can(resource, actor, action_spec, test.record)

        :assert_cannot ->
          do_assert_cannot(resource, actor, action_spec, test.record)

        :assert_fields_visible ->
          do_assert_fields_visible(resource, actor, action_spec, test.fields)

        :assert_fields_hidden ->
          do_assert_fields_hidden(resource, actor, action_spec, test.fields)
      end

      duration = System.monotonic_time(:microsecond) - start_time
      Result.pass(test.name, duration)
    rescue
      e in AshGrant.PolicyTest.AssertionError ->
        duration = System.monotonic_time(:microsecond) - start_time
        Result.fail(test.name, e.message, duration)

      e ->
        duration = System.monotonic_time(:microsecond) - start_time
        Result.fail(test.name, "Unexpected error: #{Exception.message(e)}", duration)
    end
  end

  # Direct assertion implementation (without needing a module)
  defp do_assert_can(resource, actor, action_spec, record) do
    case check_permission(resource, actor, action_spec, record) do
      {:allow, _} ->
        :ok

      {:deny, details} ->
        raise AshGrant.PolicyTest.AssertionError,
          message: "Expected allow, got deny: #{inspect(details)}"
    end
  end

  defp do_assert_cannot(resource, actor, action_spec, record) do
    case check_permission(resource, actor, action_spec, record) do
      {:deny, _} ->
        :ok

      {:allow, details} ->
        raise AshGrant.PolicyTest.AssertionError,
          message: "Expected deny, got allow: #{inspect(details)}"
    end
  end

  defp do_assert_fields_visible(resource, actor, action_spec, fields) do
    visible = Assertions.resolve_visible_fields(resource, actor, action_spec)

    case visible do
      :all_fields ->
        :ok

      :no_access ->
        raise AshGrant.PolicyTest.AssertionError,
          message:
            "Expected fields #{inspect(fields)} to be visible, but the actor has no permission"

      field_set ->
        hidden = Enum.reject(fields, &(&1 in field_set))

        if hidden == [] do
          :ok
        else
          raise AshGrant.PolicyTest.AssertionError,
            message:
              "Expected fields #{inspect(hidden)} to be visible, but they were hidden. " <>
                "Visible fields: #{inspect(field_set)}"
        end
    end
  end

  defp do_assert_fields_hidden(resource, actor, action_spec, fields) do
    visible = Assertions.resolve_visible_fields(resource, actor, action_spec)

    case visible do
      :all_fields ->
        raise AshGrant.PolicyTest.AssertionError,
          message:
            "Expected fields #{inspect(fields)} to be hidden, but the actor has a 4-part " <>
              "permission with no field restriction (all fields visible)"

      :no_access ->
        :ok

      field_set ->
        exposed = Enum.filter(fields, &(&1 in field_set))

        if exposed == [] do
          :ok
        else
          raise AshGrant.PolicyTest.AssertionError,
            message:
              "Expected fields #{inspect(exposed)} to be hidden, but they were visible. " <>
                "Visible fields: #{inspect(field_set)}"
        end
    end
  end

  defp check_permission(resource, actor, {:action_type, type}, record) do
    actions = Ash.Resource.Info.actions(resource)
    matching = Enum.filter(actions, &(&1.type == type))

    if matching == [] do
      {:deny, %{reason: :no_matching_action_type}}
    else
      find_first_allowed(matching, resource, actor, record)
    end
  end

  defp check_permission(resource, actor, action, record) do
    check_single_permission(resource, actor, action, record)
  end

  defp find_first_allowed(matching, resource, actor, record) do
    results = Enum.map(matching, &check_single_permission(resource, actor, &1.name, record))

    case Enum.find(results, fn {status, _} -> status == :allow end) do
      nil -> {:deny, %{reason: :no_permission}}
      allow -> allow
    end
  end

  defp check_single_permission(resource, actor, action, nil) do
    AshGrant.Introspect.can?(resource, action, actor)
  end

  defp check_single_permission(resource, actor, action, record) do
    case AshGrant.Introspect.can?(resource, action, actor) do
      {:deny, _} = deny -> deny
      {:allow, details} -> verify_scope_against_record(resource, actor, record, details)
    end
  end

  defp verify_scope_against_record(_resource, _actor, _record, %{scope: nil} = details) do
    {:allow, details}
  end

  defp verify_scope_against_record(resource, actor, record, details) do
    scope_name = details[:scope]

    if scope_name == nil or scope_name == "always" or scope_name == "all" or
         scope_name == "global" do
      {:allow, details}
    else
      evaluate_scope_for_record(resource, actor, record, details, scope_name)
    end
  end

  defp evaluate_scope_for_record(resource, actor, record, details, scope_name) do
    scope_atom = if is_binary(scope_name), do: String.to_atom(scope_name), else: scope_name
    filter = AshGrant.Info.resolve_scope_filter(resource, scope_atom, %{actor: actor})

    if Assertions.evaluate_filter_against_record(filter, record, actor, resource) do
      {:allow, details}
    else
      {:deny, %{reason: :scope_mismatch}}
    end
  end
end

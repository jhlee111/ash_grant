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

  ### Argument-based scopes

  Scopes can reference action arguments via `^arg(:name)`. To exercise those
  in a YAML test, supply an `arguments:` map alongside `record:`:

      - name: "manager can update refund in their unit"
        assert_can:
          actor: unit_manager
          action: update
          record:
            author_id: "u1"
          arguments:
            center_id: "center_A"

  ## Usage

      # Parse YAML file
      {:ok, parsed} = YamlParser.parse_file("policy_tests/document.yaml")

      # Run tests from YAML file
      {:ok, results} = YamlParser.run_yaml_tests("policy_tests/document.yaml")
  """

  alias AshGrant.PolicyTest.{Assertions, Checker, Result}

  @type parsed_test :: %{
          name: String.t(),
          type: :assert_can | :assert_cannot | :assert_fields_visible | :assert_fields_hidden,
          actor: atom() | String.t(),
          action: atom() | nil,
          action_type: atom() | nil,
          record: map() | nil,
          arguments: map(),
          fields: [atom()] | nil
        }

  @type parsed :: %{
          resource: module(),
          actors: %{(atom() | String.t()) => map()},
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

  # The resource first: once it is loaded, the names it declares (actions,
  # attributes, scopes, the enum values its scopes compare against) exist as
  # atoms, so the rest of the file converts to existing atoms only (#143).
  defp transform(yaml) when is_map(yaml) do
    resource = parse_resource(yaml["resource"])

    %{
      resource: resource,
      actors: parse_actors(yaml["actors"]),
      tests: parse_tests(yaml["tests"], resource)
    }
  end

  # The one atom a policy test file may create: a module that is not loaded yet
  # has no atom, and loading it needs one. A policy test file is checked-in
  # source, and this is one atom per file.
  defp parse_resource(resource_str) when is_binary(resource_str) do
    module = Module.concat([resource_str])

    if Code.ensure_loaded?(module) and Ash.Resource.Info.resource?(module) do
      module
    else
      raise ArgumentError, "resource: #{resource_str} is not a loaded Ash resource"
    end
  end

  defp parse_actors(nil), do: %{}

  defp parse_actors(actors) when is_map(actors) do
    actors
    |> Enum.map(fn {name, attrs} ->
      {atomize_key(name), atomize_map(attrs)}
    end)
    |> Enum.into(%{})
  end

  defp parse_tests(nil, _resource), do: []

  defp parse_tests(tests, resource) when is_list(tests) do
    Enum.map(tests, &parse_test(&1, resource))
  end

  defp parse_test(test, resource) do
    name = test["name"]

    cond do
      Map.has_key?(test, "assert_can") ->
        parse_assertion(:assert_can, name, test["assert_can"], resource)

      Map.has_key?(test, "assert_cannot") ->
        parse_assertion(:assert_cannot, name, test["assert_cannot"], resource)

      Map.has_key?(test, "assert_fields_visible") ->
        parse_field_assertion(
          :assert_fields_visible,
          name,
          test["assert_fields_visible"],
          resource
        )

      Map.has_key?(test, "assert_fields_hidden") ->
        parse_field_assertion(:assert_fields_hidden, name, test["assert_fields_hidden"], resource)

      true ->
        raise "Test must have assert_can, assert_cannot, assert_fields_visible, or assert_fields_hidden: #{inspect(test)}"
    end
  end

  defp parse_assertion(type, name, assertion, resource) do
    %{
      name: name,
      type: type,
      actor: atomize_key(assertion["actor"]),
      action: parse_action(assertion["action"], resource),
      action_type: parse_action_type(assertion["action_type"]),
      record: parse_record(assertion["record"]),
      arguments: parse_arguments(assertion["arguments"])
    }
  end

  defp parse_arguments(nil), do: %{}
  defp parse_arguments(args) when is_map(args), do: atomize_map(args)

  defp parse_field_assertion(type, name, assertion, resource) do
    fields =
      assertion["fields"]
      |> List.wrap()
      |> Enum.map(&atomize_key/1)

    %{
      name: name,
      type: type,
      actor: atomize_key(assertion["actor"]),
      action: parse_action(assertion["action"], resource),
      action_type: nil,
      record: nil,
      arguments: %{},
      fields: fields
    }
  end

  defp parse_action(nil, _resource), do: nil

  defp parse_action(action, resource) when is_binary(action) do
    with atom when is_atom(atom) <- existing_atom(action),
         %{} <- Ash.Resource.Info.action(resource, atom) do
      atom
    else
      _ -> raise ArgumentError, "unknown action #{inspect(action)} on #{inspect(resource)}"
    end
  end

  defp parse_action(action, _resource) when is_atom(action), do: action

  @action_types ~w(read create update destroy action)

  defp parse_action_type(nil), do: nil
  defp parse_action_type(type) when type in @action_types, do: String.to_existing_atom(type)

  defp parse_action_type(type) when is_binary(type),
    do:
      raise(
        ArgumentError,
        "unknown action_type #{inspect(type)} (expected one of #{Enum.join(@action_types, ", ")})"
      )

  defp parse_action_type(type) when is_atom(type), do: type

  defp parse_record(nil), do: nil

  defp parse_record(record) when is_map(record) do
    atomize_map(record)
  end

  # A key or value converts only to an atom that already exists. Anything a
  # scope can compare against is one (an attribute, an `^actor(...)` field, an
  # enum value), so a string that is not an atom names nothing a scope reads and
  # stays a string. Both sides of a lookup convert the same way, so an actor
  # name that stays a string still finds its actor.
  defp atomize_key(key) when is_binary(key), do: existing_atom(key) || key
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
      existing_atom(value) || value
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

    action_spec =
      cond do
        test.action_type != nil -> {:action_type, test.action_type}
        test.action != nil -> test.action
        true -> raise "Test must have action or action_type: #{inspect(test)}"
      end

    arguments = Map.get(test, :arguments, %{})

    try do
      actor = fetch_actor!(actors, test.actor)

      case test.type do
        :assert_can ->
          do_assert_can(resource, actor, action_spec, test.record, arguments)

        :assert_cannot ->
          do_assert_cannot(resource, actor, action_spec, test.record, arguments)

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

  # Same rule and message as the DSL's: a misspelled actor is a failing test, not
  # an actor with no permissions (which would quietly pass every assert_cannot).
  defp fetch_actor!(_actors, nil) do
    raise AshGrant.PolicyTest.AssertionError, message: "The assertion has no `actor:` key"
  end

  defp fetch_actor!(actors, name) do
    case Map.get(actors, name) do
      nil ->
        raise AshGrant.PolicyTest.AssertionError,
          message: "Actor :#{name} not defined. Available actors: #{inspect(Map.keys(actors))}"

      actor ->
        actor
    end
  end

  # Direct assertion implementation (without needing a module)
  defp do_assert_can(resource, actor, action_spec, record, arguments) do
    case Checker.check(resource, actor, action_spec, record, arguments) do
      {:allow, _} ->
        :ok

      {:deny, details} ->
        raise AshGrant.PolicyTest.AssertionError,
          message: "Expected allow, got deny: #{inspect(details)}"

      {:indeterminate, details} ->
        raise AshGrant.PolicyTest.AssertionError,
          message: "Cannot decide: #{Checker.undecided_reason(details)}"
    end
  end

  defp do_assert_cannot(resource, actor, action_spec, record, arguments) do
    case Checker.check(resource, actor, action_spec, record, arguments) do
      {:deny, _} ->
        :ok

      {:allow, details} ->
        raise AshGrant.PolicyTest.AssertionError,
          message: "Expected deny, got allow: #{inspect(details)}"

      {:indeterminate, details} ->
        raise AshGrant.PolicyTest.AssertionError,
          message: "Cannot decide: #{Checker.undecided_reason(details)}"
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

  defp existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end

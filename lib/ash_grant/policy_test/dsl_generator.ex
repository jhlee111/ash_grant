defmodule AshGrant.PolicyTest.DslGenerator do
  @moduledoc """
  Generates Elixir DSL code from YAML policy test files.

  This allows converting YAML policy tests to Elixir DSL for:
  - Importing tests from external tools
  - Converting documentation to executable tests
  - Migrating from YAML to DSL format

  ## Examples

      code = DslGenerator.generate("policy_tests/document.yaml")
      File.write!("test/policy_tests/document_test.exs", code)
  """

  alias AshGrant.PolicyTest.YamlParser

  @doc """
  Generates Elixir DSL code from a YAML file.
  """
  @spec generate(String.t()) :: String.t()
  def generate(yaml_path) do
    {:ok, parsed} = YamlParser.parse_file(yaml_path)
    generate_from_parsed(parsed, yaml_path)
  end

  @doc """
  Generates Elixir DSL code from parsed YAML data.
  """
  @spec generate_from_parsed(map(), String.t() | nil) :: String.t()
  def generate_from_parsed(parsed, yaml_path \\ nil) do
    module_name = derive_module_name(parsed.resource, yaml_path)

    """
    defmodule #{module_name} do
      use AshGrant.PolicyTest

      resource #{inspect(parsed.resource)}

    #{generate_actors(parsed.actors)}
    #{generate_tests(parsed.tests)}
    end
    """
    |> String.trim_trailing()
  end

  # Private functions

  defp derive_module_name(resource, nil) do
    resource_name =
      resource
      |> Atom.to_string()
      |> String.replace_prefix("Elixir.", "")
      |> String.split(".")
      |> List.last()

    "#{resource_name}PolicyTest"
  end

  defp derive_module_name(_resource, yaml_path) do
    yaml_path
    |> Path.basename(".yaml")
    |> Macro.camelize()
    |> Kernel.<>("PolicyTest")
  end

  defp generate_actors(actors) do
    Enum.map_join(actors, "\n", fn {name, attrs} ->
      "  actor :#{name}, #{inspect(attrs)}"
    end)
  end

  defp generate_tests(tests) do
    Enum.map_join(tests, "\n\n", &generate_test/1)
  end

  defp generate_test(test) do
    assertion = generate_assertion(test)

    """
      test "#{test.name}" do
        #{assertion}
      end
    """
    |> String.trim_trailing()
  end

  defp generate_assertion(test) do
    actor = ":#{test.actor}"
    action_spec = generate_action_spec(test)
    record = test[:record]
    arguments = Map.get(test, :arguments, %{}) || %{}

    case test.type do
      :assert_can ->
        "assert_can #{actor}, #{action_spec}#{third_arg(record, arguments)}"

      :assert_cannot ->
        "assert_cannot #{actor}, #{action_spec}#{third_arg(record, arguments)}"

      :assert_fields_visible ->
        fields_list = generate_fields_list(test.fields)
        "assert_fields_visible #{actor}, #{action_spec}, #{fields_list}"

      :assert_fields_hidden ->
        fields_list = generate_fields_list(test.fields)
        "assert_fields_hidden #{actor}, #{action_spec}, #{fields_list}"
    end
  end

  # Produce either `", %{...}"` (record only), `", [record: %{...}, arguments: %{...}]"`,
  # `", [arguments: %{...}]"`, or empty string.
  defp third_arg(nil, args) when args == %{}, do: ""

  defp third_arg(record, args) when args == %{} do
    ", " <> generate_record(record)
  end

  defp third_arg(record, args) do
    parts =
      []
      |> maybe_add(:record, record, &generate_record/1)
      |> maybe_add(:arguments, args, &generate_record/1)
      |> Enum.reverse()
      |> Enum.join(", ")

    ", [" <> parts <> "]"
  end

  defp maybe_add(acc, _key, nil, _fmt), do: acc

  defp maybe_add(acc, _key, empty, _fmt) when empty == %{}, do: acc

  defp maybe_add(acc, key, value, fmt), do: ["#{key}: #{fmt.(value)}" | acc]

  defp generate_fields_list(fields) do
    inner = Enum.map_join(fields, ", ", &":#{&1}")
    "[#{inner}]"
  end

  defp generate_action_spec(test) do
    cond do
      test.action_type != nil ->
        "action_type: :#{test.action_type}"

      test.action != nil ->
        ":#{test.action}"

      true ->
        raise "Test must have action or action_type"
    end
  end

  defp generate_record(nil), do: nil

  defp generate_record(record) do
    inner =
      Enum.map_join(record, ", ", fn {k, v} ->
        "#{k}: #{inspect(v)}"
      end)

    "%{#{inner}}"
  end
end

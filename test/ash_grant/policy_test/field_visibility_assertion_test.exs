defmodule AshGrant.PolicyTest.FieldVisibilityAssertionTest do
  @moduledoc """
  Tests for the field visibility assertion macros (assert_fields_visible, assert_fields_hidden).
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.Fixtures.FieldVisibilityTest
  alias AshGrant.PolicyTest.AssertionError

  describe "assert_fields_visible" do
    test "passes for fields in actor's resolved field groups" do
      result = run_test(FieldVisibilityTest, "public viewer sees non-sensitive fields")
      assert result == :ok
    end

    test "passes for all fields when actor has full field group" do
      result = run_test(FieldVisibilityTest, "full viewer sees all fields")
      assert result == :ok
    end

    test "passes for 4-part permission (no field restriction)" do
      result = run_test(FieldVisibilityTest, "unrestricted sees all fields (4-part permission)")
      assert result == :ok
    end

    test "raises for fields NOT in actor's groups" do
      assert_raise AssertionError, ~r/hidden/, fn ->
        AshGrant.PolicyTest.Assertions.do_assert_fields_visible(
          FieldVisibilityTest,
          :public_viewer,
          :read,
          [:salary, :ssn]
        )
      end
    end

    test "raises when actor has no permission" do
      assert_raise AssertionError, ~r/no permission/, fn ->
        AshGrant.PolicyTest.Assertions.do_assert_fields_visible(
          FieldVisibilityTest,
          :nobody,
          :read,
          [:name]
        )
      end
    end
  end

  describe "assert_fields_hidden" do
    test "passes for fields not in actor's groups" do
      result = run_test(FieldVisibilityTest, "public viewer cannot see salary and ssn")
      assert result == :ok
    end

    test "passes when actor has no permission (all hidden)" do
      result = run_test(FieldVisibilityTest, "nobody has no visible fields")
      assert result == :ok
    end

    test "raises for fields that ARE in actor's groups" do
      assert_raise AssertionError, ~r/visible/, fn ->
        AshGrant.PolicyTest.Assertions.do_assert_fields_hidden(
          FieldVisibilityTest,
          :full_viewer,
          :read,
          [:salary, :ssn]
        )
      end
    end

    test "raises when actor has 4-part permission (all fields visible)" do
      assert_raise AssertionError, ~r/4-part permission/, fn ->
        AshGrant.PolicyTest.Assertions.do_assert_fields_hidden(
          FieldVisibilityTest,
          :unrestricted,
          :read,
          [:salary]
        )
      end
    end
  end

  describe "multiple field groups" do
    test "union of fields from multiple groups" do
      # full_viewer has :full which inherits :public and adds [:salary, :ssn]
      # So all fields should be visible
      assert :ok ==
               AshGrant.PolicyTest.Assertions.do_assert_fields_visible(
                 FieldVisibilityTest,
                 :full_viewer,
                 :read,
                 [:name, :email, :department, :salary, :ssn]
               )
    end
  end

  describe "YAML parsing" do
    test "parses assert_fields_visible from YAML" do
      yaml_content = """
      resource: AshGrant.Test.ExceptRecord

      actors:
        viewer:
          permissions:
            - "exceptrecord:*:read:always:public"

      tests:
        - name: "viewer sees public fields"
          assert_fields_visible:
            actor: viewer
            action: read
            fields: [name, email]
      """

      {:ok, parsed} = parse_yaml_string(yaml_content)
      [test] = parsed.tests

      assert test.type == :assert_fields_visible
      assert test.actor == :viewer
      assert test.action == :read
      assert test.fields == [:name, :email]
    end

    test "parses assert_fields_hidden from YAML" do
      yaml_content = """
      resource: AshGrant.Test.ExceptRecord

      actors:
        viewer:
          permissions:
            - "exceptrecord:*:read:always:public"

      tests:
        - name: "viewer cannot see sensitive"
          assert_fields_hidden:
            actor: viewer
            action: read
            fields: [salary, ssn]
      """

      {:ok, parsed} = parse_yaml_string(yaml_content)
      [test] = parsed.tests

      assert test.type == :assert_fields_hidden
      assert test.actor == :viewer
      assert test.action == :read
      assert test.fields == [:salary, :ssn]
    end
  end

  describe "DSL generation" do
    test "generates assert_fields_visible code" do
      parsed_test = %{
        name: "viewer sees fields",
        type: :assert_fields_visible,
        actor: :viewer,
        action: :read,
        action_type: nil,
        fields: [:name, :email]
      }

      code = generate_assertion_code(parsed_test)
      assert code =~ "assert_fields_visible :viewer, :read, [:name, :email]"
    end

    test "generates assert_fields_hidden code" do
      parsed_test = %{
        name: "viewer cannot see fields",
        type: :assert_fields_hidden,
        actor: :viewer,
        action: :read,
        action_type: nil,
        fields: [:salary, :ssn]
      }

      code = generate_assertion_code(parsed_test)
      assert code =~ "assert_fields_hidden :viewer, :read, [:salary, :ssn]"
    end
  end

  # Helpers

  defp run_test(module, test_name) do
    tests = module.__policy_test__(:tests)

    case Enum.find(tests, &(&1.name == test_name)) do
      nil ->
        raise "Test not found: #{test_name}. Available: #{inspect(Enum.map(tests, & &1.name))}"

      test_def ->
        context = module.__policy_test__(:context)
        test_def.fun.(context)
    end
  end

  defp parse_yaml_string(content) do
    if Code.ensure_loaded?(YamlElixir) do
      {:ok, yaml} = YamlElixir.read_from_string(content)

      parsed = %{
        resource: parse_resource(yaml["resource"]),
        actors: parse_actors(yaml["actors"]),
        tests: parse_tests(yaml["tests"])
      }

      {:ok, parsed}
    else
      {:error, :yaml_elixir_not_available}
    end
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
      {String.to_atom(name), atomize_map(attrs)}
    end)
    |> Enum.into(%{})
  end

  defp parse_tests(tests) when is_list(tests) do
    Enum.map(tests, fn test ->
      name = test["name"]

      cond do
        Map.has_key?(test, "assert_fields_visible") ->
          a = test["assert_fields_visible"]

          %{
            name: name,
            type: :assert_fields_visible,
            actor: String.to_atom(a["actor"]),
            action: String.to_atom(a["action"]),
            action_type: nil,
            record: nil,
            fields: Enum.map(a["fields"], &String.to_atom/1)
          }

        Map.has_key?(test, "assert_fields_hidden") ->
          a = test["assert_fields_hidden"]

          %{
            name: name,
            type: :assert_fields_hidden,
            actor: String.to_atom(a["actor"]),
            action: String.to_atom(a["action"]),
            action_type: nil,
            record: nil,
            fields: Enum.map(a["fields"], &String.to_atom/1)
          }
      end
    end)
  end

  defp atomize_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize_value(v)} end)
    |> Enum.into(%{})
  end

  defp atomize_value(v) when is_binary(v), do: v
  defp atomize_value(v) when is_list(v), do: v
  defp atomize_value(v), do: v

  defp generate_assertion_code(test) do
    # Use the DslGenerator to generate code for a parsed test
    parsed = %{
      resource: AshGrant.Test.ExceptRecord,
      actors: %{viewer: %{permissions: ["exceptrecord:*:read:always:public"]}},
      tests: [test]
    }

    AshGrant.PolicyTest.DslGenerator.generate_from_parsed(parsed)
  end
end

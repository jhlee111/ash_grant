defmodule AshGrant.PolicyTest do
  @moduledoc """
  DSL-based policy configuration testing for AshGrant.

  This module provides a declarative way to test policy configurations
  without requiring a database. It tests **policy configuration**, not data.

  ## Key Concept

  | Traditional Unit Test | Policy Configuration Test |
  |----------------------|--------------------------|
  | Tests library behavior | Verifies user's policy setup |
  | Requires DB records | No data needed |
  | "Did Ash return right records?" | "Can actor X do action Y?" |
  | `mix test` | `mix ash_grant.verify` |

  ## Usage

      defmodule MyApp.PolicyTests.DocumentPolicyTest do
        use AshGrant.PolicyTest

        resource MyApp.Document

        actor :reader, %{role: :reader}
        actor :author, %{role: :author, id: "author_001"}
        actor :guest, %{permissions: []}

        describe "read access" do
          test "reader can read" do
            assert_can :reader, :read
          end

          test "guest cannot read" do
            assert_cannot :guest, :read
          end

          test "reader can read published documents" do
            assert_can :reader, :read, %{status: :published}
          end
        end

        describe "update access" do
          test "author can update own drafts" do
            assert_can :author, :update, %{author_id: "author_001", status: :draft}
          end
        end
      end

  ## Action Specifiers

  You can specify actions in several ways:

      assert_can :actor, :read                    # shorthand for action: :read
      assert_can :actor, action: :approve         # specific action name
      assert_can :actor, action_type: :update     # any action of this type

  ## Running Tests

      # Run all policy tests
      mix ash_grant.verify

      # Run specific file
      mix ash_grant.verify test/policy_tests/document_test.exs

      # Run with verbose output
      mix ash_grant.verify --verbose
  """

  @doc """
  Sets up the PolicyTest DSL for a module.

  When you `use AshGrant.PolicyTest`, it imports all the DSL macros
  and sets up the module attributes needed to track resources, actors, and tests.
  """
  defmacro __using__(_opts) do
    quote do
      import AshGrant.PolicyTest.Dsl
      import AshGrant.PolicyTest.Assertions

      Module.register_attribute(__MODULE__, :policy_test_resource, accumulate: false)
      Module.register_attribute(__MODULE__, :policy_test_actors, accumulate: true)
      Module.register_attribute(__MODULE__, :policy_test_tests, accumulate: true)
      Module.register_attribute(__MODULE__, :policy_test_current_describe, accumulate: false)

      @before_compile AshGrant.PolicyTest
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    tests = Module.get_attribute(env.module, :policy_test_tests) |> Enum.reverse()

    test_functions = generate_test_functions(tests)
    fallback_function = generate_fallback_function(tests)
    test_entries = build_test_entries(tests)

    quote do
      def __policy_test__(:resource), do: @policy_test_resource

      def __policy_test__(:actors) do
        @policy_test_actors |> Enum.reverse() |> Enum.into(%{})
      end

      def __policy_test__(:tests) do
        entries = unquote(Macro.escape(test_entries))

        Enum.map(entries, fn entry ->
          Map.put(entry, :fun, fn context -> __run_test__(entry.index, context) end)
        end)
      end

      def __policy_test__(:context) do
        %{resource: __policy_test__(:resource), actors: __policy_test__(:actors)}
      end

      unquote_splicing(test_functions)
      unquote(fallback_function)
    end
  end

  defp generate_test_functions(tests) do
    for {test, index} <- Enum.with_index(tests) do
      body = test.body

      quote do
        def __run_test__(unquote(index), _context), do: unquote(body)
      end
    end
  end

  defp generate_fallback_function([]) do
    quote do
      def __run_test__(_index, _context), do: raise("No tests defined")
    end
  end

  defp generate_fallback_function(_tests) do
    quote do
      def __run_test__(index, _context), do: raise("Unknown test index: #{index}")
    end
  end

  # `body` is the test's quoted block, kept so `YamlExporter` can read the
  # assertions back out; the compiled `__run_test__/2` clause is what runs.
  defp build_test_entries(tests) do
    for {test, index} <- Enum.with_index(tests) do
      %{name: test.name, describe: test.describe, index: index, body: test.body}
    end
  end

  @doc """
  Converts a policy test module to YAML format.

  The YAML tests exactly what the module tests, or this raises `ArgumentError`
  naming every test it cannot express: test bodies must be assertion calls with
  literal arguments, and a test with several assertions becomes several YAML
  tests. See `AshGrant.PolicyTest.YamlExporter` for the rules.

  ## Examples

      AshGrant.PolicyTest.to_yaml(MyApp.PolicyTests.DocumentTest)
      # => "resource: \\"MyApp.Document\\"\\nactors:\\n  reader:\\n    role: \\"reader\\"\\n..."
  """
  @spec to_yaml(module()) :: String.t()
  def to_yaml(module) do
    AshGrant.PolicyTest.YamlExporter.export(module)
  end

  @doc """
  Generates DSL code from a YAML file.

  ## Examples

      AshGrant.PolicyTest.to_dsl("priv/policy_tests/document.yaml")
      # => "defmodule DocumentPolicyTest do\\n  use AshGrant.PolicyTest\\n..."
  """
  @spec to_dsl(String.t()) :: String.t()
  def to_dsl(yaml_path) do
    AshGrant.PolicyTest.DslGenerator.generate(yaml_path)
  end
end

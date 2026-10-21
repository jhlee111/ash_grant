# The fixtures live outside the ExUnit module: nested there, `use AshGrant.PolicyTest`'s
# `test/2` would collide with the one ExUnit.Case imports.

defmodule AshGrant.PolicyTest.YamlExport.ShapesPolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Post)

  actor(:editor, %{id: "editor-001", permissions: ["post:*:read:always", "post:*:update:own"]})

  test "bare record" do
    assert_can(:editor, :read, %{status: :published, author_id: "editor-001"})
  end

  test "record and arguments" do
    assert_can(:editor, :update,
      record: %{author_id: "editor-001"},
      arguments: %{center_id: "center-a"}
    )
  end

  test "action type" do
    assert_cannot(:editor, action_type: :destroy)
  end

  test "named action" do
    assert_can(:editor, action: :read)
  end

  test "fields" do
    assert_fields_visible(:editor, :read, [:title, :status])
  end

  describe "grouped" do
    test "two assertions" do
      assert_can(:editor, :read)
      assert_cannot(:editor, :destroy)
    end
  end
end

defmodule AshGrant.PolicyTest.YamlExport.UnexportablePolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Post)

  actor(:reader, %{permissions: ["post:*:read:always"]})
  actor(:nobody, nil)

  test "computed record" do
    record = %{status: :published}
    assert_can(:reader, :read, record)
  end

  test "no assertion" do
    :ok
  end

  test "date value" do
    assert_can(:reader, :read, %{published_on: ~D[2026-01-01]})
  end

  test "capitalized atom" do
    assert_can(:reader, :read, %{status: :Published})
  end

  test "nested map" do
    assert_can(:reader, :read, %{author: %{id: "a-1"}})
  end

  test "exportable" do
    assert_can(:reader, :read)
  end
end

defmodule AshGrant.PolicyTest.YamlExportTest do
  @moduledoc """
  `YamlExporter.export/1` must write YAML that tests exactly what the DSL module
  tests, or refuse (#143). It used to emit `actor: "unknown"` placeholders for
  every DSL test.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.{Runner, YamlExporter, YamlParser}
  alias AshGrant.PolicyTest.YamlExport.{ShapesPolicyTest, UnexportablePolicyTest}

  alias AshGrant.PolicyTest.Fixtures.{
    DocumentPolicyTest,
    ExceptFieldGroupTest,
    FailFastTest,
    FeedPolicyTest,
    FieldVisibilityTest,
    GenericActionPolicyTest,
    MissingFieldTest,
    MultiAssertTest,
    PostPolicyTest,
    ScopeThroughTest,
    SpecialCharsTest,
    UndefinedActorTest
  }

  @moduletag :tmp_dir

  defp write_export(module, dir) do
    path = Path.join(dir, "#{inspect(module)}.yaml")
    File.write!(path, YamlExporter.export(module))
    path
  end

  defp assertion_count(%{body: {:__block__, _, exprs}}), do: length(exprs)
  defp assertion_count(%{body: _}), do: 1

  describe "round trip" do
    # Includes modules whose tests fail on purpose: the YAML must fail them too.
    @exportable [
      DocumentPolicyTest,
      ExceptFieldGroupTest,
      FailFastTest,
      FeedPolicyTest,
      FieldVisibilityTest,
      GenericActionPolicyTest,
      MissingFieldTest,
      MultiAssertTest,
      PostPolicyTest,
      ScopeThroughTest,
      SpecialCharsTest,
      UndefinedActorTest
    ]

    test "the YAML runner gives every exported test the DSL's outcome", %{tmp_dir: dir} do
      for module <- @exportable do
        {:ok, yaml_results} = module |> write_export(dir) |> YamlParser.run_yaml_tests()
        yaml = Map.new(yaml_results, &{&1.test_name, &1.passed})

        expected_names =
          for test <- module.__policy_test__(:tests),
              name <- split_names(test.name, assertion_count(test)),
              do: name

        assert Enum.sort(Map.keys(yaml)) == Enum.sort(expected_names),
               "#{inspect(module)}: exported tests do not match its assertions"

        for result <- Runner.run_module(module) do
          test = Enum.find(module.__policy_test__(:tests), &(&1.name == result.test_name))
          parts = split_names(result.test_name, assertion_count(test))

          assert result.passed == Enum.all?(parts, &yaml[&1]),
                 "#{inspect(module)}: #{inspect(result.test_name)} passed=#{result.passed} " <>
                   "in the DSL but YAML gave #{inspect(Map.take(yaml, parts))}"
        end
      end
    end

    defp split_names(name, 1), do: [name]
    defp split_names(name, count), do: for(i <- 1..count, do: "#{name} (#{i}/#{count})")
  end

  describe "export/1" do
    test "writes each assertion's actor, action, record, arguments and fields", %{tmp_dir: dir} do
      {:ok, parsed} = ShapesPolicyTest |> write_export(dir) |> YamlParser.parse_file()

      assert parsed.resource == AshGrant.Test.Post

      assert parsed.actors == %{
               editor: %{
                 id: "editor-001",
                 permissions: ["post:*:read:always", "post:*:update:own"]
               }
             }

      tests = Map.new(parsed.tests, &{&1.name, &1})

      assert %{
               type: :assert_can,
               actor: :editor,
               action: :read,
               record: %{status: :published, author_id: "editor-001"}
             } = tests["bare record"]

      assert %{
               type: :assert_can,
               action: :update,
               record: %{author_id: "editor-001"},
               arguments: %{center_id: "center-a"}
             } = tests["record and arguments"]

      assert %{type: :assert_cannot, action: nil, action_type: :destroy, record: nil} =
               tests["action type"]

      assert %{type: :assert_can, action: :read, action_type: nil} = tests["named action"]

      assert %{type: :assert_fields_visible, action: :read, fields: [:title, :status]} =
               tests["fields"]

      assert %{type: :assert_can, action: :read} = tests["grouped: two assertions (1/2)"]
      assert %{type: :assert_cannot, action: :destroy} = tests["grouped: two assertions (2/2)"]
      assert map_size(tests) == 7
    end

    test "refuses a module it cannot export faithfully, naming every reason" do
      error = assert_raise ArgumentError, fn -> YamlExporter.export(UnexportablePolicyTest) end

      for fragment <- [
            "actor :nobody",
            ~s("computed record"),
            ~s("no assertion"),
            ~s("date value"),
            ~s("capitalized atom"),
            ~s("nested map")
          ] do
        assert error.message =~ fragment
      end

      refute error.message =~ ~s("exportable")
    end
  end
end

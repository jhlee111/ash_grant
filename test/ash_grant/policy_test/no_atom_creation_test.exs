defmodule AshGrant.PolicyTest.NoAtomCreationTest do
  @moduledoc """
  Input that AshGrant does not control (a YAML policy test file, permission
  strings from the resolver) must not create atoms. The atom table is never
  garbage-collected, so every new identifier-like string grows it for good (#143).

  An identifier that names something real is already an atom, since the
  resource that declares it is loaded: an action, an attribute, a scope, a field
  group, an enum value a scope compares against. Those keep converting. Anything
  else stays a string or, where it must name something, is an error.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.{Assertions, YamlParser}
  alias AshGrant.Test.Document

  @moduletag :tmp_dir

  # A string no module mentions, so its atom exists only if the code under test
  # created it.
  defp unseen(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}_unseen"

  defp atom_exists?(string) do
    _ = String.to_existing_atom(string)
    true
  rescue
    ArgumentError -> false
  end

  defp write_yaml(dir, body) do
    path = Path.join(dir, "policy_#{System.unique_integer([:positive])}.yaml")
    File.write!(path, body)
    path
  end

  describe "YAML policy tests" do
    test "an identifier-like value that is not an atom stays a string", %{tmp_dir: dir} do
      value = unseen("val")

      path =
        write_yaml(dir, """
        resource: AshGrant.Test.Document
        actors:
          reader:
            role: reader
            team: #{value}
        tests:
          - name: "reader can read approved"
            assert_can:
              actor: reader
              action: read
              record:
                status: approved
                title: #{value}
        """)

      assert {:ok, parsed} = YamlParser.parse_file(path)
      refute atom_exists?(value)

      [test] = parsed.tests
      assert test.record.title == value
      assert test.record.status == :approved
      assert parsed.actors.reader.team == value
      assert parsed.actors.reader.role == :reader
    end

    test "an unknown key stays a string; an attribute name is an atom", %{tmp_dir: dir} do
      key = unseen("key")

      path =
        write_yaml(dir, """
        resource: AshGrant.Test.Document
        actors:
          reader:
            role: reader
        tests:
          - name: "reader can read approved"
            assert_can:
              actor: reader
              action: read
              record:
                status: approved
                #{key}: "some text"
        """)

      assert {:ok, parsed} = YamlParser.parse_file(path)
      refute atom_exists?(key)
      [test] = parsed.tests
      assert Map.fetch!(test.record, key) == "some text"
      assert Map.fetch!(test.record, :status) == :approved
    end

    test "an actor named by a non-atom still runs, on both sides of the lookup", %{tmp_dir: dir} do
      name = unseen("actor")

      path =
        write_yaml(dir, """
        resource: AshGrant.Test.Document
        actors:
          #{name}:
            role: reader
        tests:
          - name: "a fresh actor name can read approved"
            assert_can:
              actor: #{name}
              action: read
              record:
                status: approved
        """)

      assert {:ok, [result]} = YamlParser.run_yaml_tests(path)
      assert result.passed, inspect(result)
      refute atom_exists?(name)
    end

    test "an action the resource does not define is an error naming it", %{tmp_dir: dir} do
      action = unseen("action")

      path =
        write_yaml(dir, """
        resource: AshGrant.Test.Document
        actors:
          reader:
            role: reader
        tests:
          - name: "typo"
            assert_can:
              actor: reader
              action: #{action}
        """)

      error = assert_raise ArgumentError, fn -> YamlParser.parse_file(path) end
      assert Exception.message(error) =~ ~s(unknown action "#{action}")
      assert Exception.message(error) =~ "AshGrant.Test.Document"
      refute atom_exists?(action)
    end

    test "an unknown action type is an error naming it", %{tmp_dir: dir} do
      path =
        write_yaml(dir, """
        resource: AshGrant.Test.Document
        actors:
          reader:
            role: reader
        tests:
          - name: "typo"
            assert_can:
              actor: reader
              action_type: reed
        """)

      error = assert_raise ArgumentError, fn -> YamlParser.parse_file(path) end
      assert Exception.message(error) =~ ~s(unknown action_type "reed")
    end

    test "a resource that is not a loaded Ash resource is an error naming it", %{tmp_dir: dir} do
      path =
        write_yaml(dir, """
        resource: AshGrant.Test.NoSuchResource
        tests: []
        """)

      error = assert_raise ArgumentError, fn -> YamlParser.parse_file(path) end
      assert Exception.message(error) =~ "AshGrant.Test.NoSuchResource"
    end
  end

  describe "permission strings" do
    test "explain/4 does not atomize an undeclared scope" do
      scope = unseen("scope")
      actor = %{id: "u1", permissions: ["document:*:read:#{scope}"]}

      explanation = AshGrant.explain(Document, :read, actor)

      refute atom_exists?(scope)
      [evaluated] = explanation.evaluated_permissions
      assert evaluated.scope_name == scope
    end

    test "explain/4 still reports a declared scope as an atom" do
      actor = %{id: "u1", permissions: ["document:*:read:approved"]}
      [evaluated] = AshGrant.explain(Document, :read, actor).evaluated_permissions
      assert evaluated.scope_name == :approved
    end

    test "policy test field visibility does not atomize an undeclared field group" do
      group = unseen("group")
      actor = %{role: :custom, permissions: ["document:*:read:always:#{group}"]}

      assert Assertions.resolve_visible_fields(Document, actor, :read) == []
      refute atom_exists?(group)
    end
  end
end

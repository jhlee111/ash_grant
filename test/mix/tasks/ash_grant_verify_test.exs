defmodule Mix.Tasks.AshGrant.VerifyTest do
  @moduledoc """
  Tests for the `mix ash_grant.verify` task.

  Like the other task tests, these call `run_cli/1` directly to avoid
  `Mix.Task.run("app.start")` and shell side effects.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshGrant.Verify

  @fixture_path "test/fixtures/policy_tests/document.yaml"

  @failing_yaml """
  resource: AshGrant.Test.Document

  actors:
    guest:
      permissions: []

  tests:
    - name: "guest can read"
      assert_can:
        actor: guest
        action: read
  """

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp policy_source(module_name, assertion \\ "assert_can(:reader, :read)") do
    """
    defmodule #{module_name} do
      use AshGrant.PolicyTest

      resource(AshGrant.Test.Document)

      actor(:reader, %{role: :reader})
      actor(:guest, %{permissions: []})

      test "#{assertion}" do
        #{assertion}
      end
    end
    """
  end

  describe "exit code" do
    test "0 when every test passes" do
      assert {:ok, output, 0} = Verify.run_cli([@fixture_path])
      assert output =~ ~r/\d+ test\(s\) passed/
    end

    @tag :tmp_dir
    test "1 when a test fails", %{tmp_dir: dir} do
      path = write(dir, "failing.yaml", @failing_yaml)

      assert {:error, output, 1} = Verify.run_cli([path])
      assert output =~ "1/1 test(s) failed"
    end

    @tag :tmp_dir
    test "2 when a YAML file does not parse", %{tmp_dir: dir} do
      path = write(dir, "broken.yaml", "tests: [unclosed\n")

      assert {:error, output, 2} = Verify.run_cli([path])
      assert output =~ "broken.yaml"
    end

    @tag :tmp_dir
    test "2 when a YAML file defines no tests", %{tmp_dir: dir} do
      # A misspelled `tests:` key parses fine and leaves nothing to run.
      path = write(dir, "typo.yaml", "resource: AshGrant.Test.Document\ntest:\n  - name: x\n")

      assert {:error, output, 2} = Verify.run_cli([path])
      assert output =~ "typo.yaml: defines no tests"
    end

    @tag :tmp_dir
    test "2 when a policy test file does not compile", %{tmp_dir: dir} do
      path =
        write(
          dir,
          "broken_test.exs",
          "defmodule VerifyTest.Broken do\n  use AshGrant.PolicyTest\n"
        )

      assert {:error, output, 2} = Verify.run_cli([path])
      assert output =~ "broken_test.exs"
      assert output =~ "missing terminator"
    end

    test "2 when the path does not exist" do
      assert {:error, output, 2} = Verify.run_cli(["test/no_such_policy_tests/"])
      assert output =~ "test/no_such_policy_tests/"
    end

    @tag :tmp_dir
    test "2 when the path is not a policy test file", %{tmp_dir: dir} do
      path = write(dir, "grants.txt", "post:*:read:always\n")

      assert {:error, output, 2} = Verify.run_cli([path])
      assert output =~ "grants.txt"
    end

    @tag :tmp_dir
    test "2 when a given directory holds no policy tests", %{tmp_dir: dir} do
      write(dir, "helper.exs", "defmodule VerifyTest.NotAPolicyTest do\nend\n")

      assert {:error, output, 2} = Verify.run_cli([dir])
      assert output =~ "#{dir}: no policy tests found"
    end

    @tag :tmp_dir
    test "2 when a given file holds no policy test module", %{tmp_dir: dir} do
      path = write(dir, "helper.exs", "defmodule VerifyTest.AlsoNotAPolicyTest do\nend\n")

      assert {:error, output, 2} = Verify.run_cli([path])
      assert output =~ "#{path}: no policy tests found"
    end

    @tag :tmp_dir
    test "2 when a given file's policy test module defines no tests", %{tmp_dir: dir} do
      path =
        write(dir, "empty_test.exs", """
        defmodule VerifyTest.NoTestsPolicyTest do
          use AshGrant.PolicyTest

          resource(AshGrant.Test.Document)
        end
        """)

      assert {:error, output, 2} = Verify.run_cli([path])
      assert output =~ "#{path}: no policy tests found"
    end

    test "2 for an unknown option" do
      assert {:error, output, 2} = Verify.run_cli([@fixture_path, "--formt", "json"])
      assert output =~ "--formt"
    end

    test "2 for an invalid --format" do
      assert {:error, output, 2} = Verify.run_cli([@fixture_path, "--format", "xml"])
      assert output =~ "xml"
    end

    @tag :tmp_dir
    test "passing tests do not hide a file that failed to load", %{tmp_dir: dir} do
      File.cp!(@fixture_path, Path.join(dir, "document.yaml"))
      write(dir, "broken.yaml", "tests: [unclosed\n")

      assert {:error, output, 2} = Verify.run_cli([dir])
      assert output =~ ~r/\d+ test\(s\) passed/
      assert output =~ "broken.yaml"
      assert output =~ "1 error(s)"
    end

    test "0 with a notice when the default locations hold no policy tests" do
      # This repository has neither test/policy_tests nor priv/policy_tests.
      assert {:ok, output, 0} = Verify.run_cli([])
      assert output =~ "No policy tests found"
    end
  end

  describe "discovery" do
    @tag :tmp_dir
    test "a directory runs its .exs policy test modules", %{tmp_dir: dir} do
      write(dir, "nested/reader_test.exs", policy_source("VerifyTest.DirExsPolicyTest"))

      assert {:ok, output, 0} = Verify.run_cli([dir])
      assert output =~ "1 test(s) passed"
    end

    @tag :tmp_dir
    test "a directory runs its YAML files", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "nested"))
      File.cp!(@fixture_path, Path.join(dir, "nested/document.yaml"))
      write(dir, "failing.yml", @failing_yaml)

      assert {:error, output, 1} = Verify.run_cli([dir])
      assert output =~ "1/"
      assert output =~ "test(s) failed"
    end

    @tag :tmp_dir
    test "a file runs only the modules it defines", %{tmp_dir: dir} do
      path = write(dir, "passing_test.exs", policy_source("VerifyTest.OnlyThisPolicyTest"))

      write(
        dir,
        "failing_test.exs",
        policy_source("VerifyTest.NotThisPolicyTest", "assert_can(:guest, :read)")
      )

      assert {:ok, output, 0} = Verify.run_cli([path])
      assert output =~ "1 test(s) passed"
    end

    @tag :tmp_dir
    test "every path given is run", %{tmp_dir: dir} do
      path = write(dir, "failing.yaml", @failing_yaml)

      assert {:error, output, 1} = Verify.run_cli([@fixture_path, path])
      assert output =~ "1/"
      assert output =~ "test(s) failed"
    end

    @tag :tmp_dir
    test "a file reached by several paths runs once", %{tmp_dir: dir} do
      path = write(dir, "once_policy_test.exs", policy_source("VerifyTest.OncePolicyTest"))

      assert {:ok, output, 0} = Verify.run_cli([dir, path, path])
      assert output =~ "1 test(s) passed"
    end

    @tag :tmp_dir
    test "a directory is not empty because a path before it ran its file", %{tmp_dir: dir} do
      path = write(dir, "named_policy_test.exs", policy_source("VerifyTest.NamedFirstPolicyTest"))
      write(dir, "helper.exs", "defmodule VerifyTest.NamedFirstHelper do\nend\n")

      assert {:ok, output, 0} = Verify.run_cli([path, dir])
      assert output =~ "1 test(s) passed"
    end

    @tag :tmp_dir
    test "a file that does not compile does not hide the files beside it", %{tmp_dir: dir} do
      write(dir, "good_policy_test.exs", policy_source("VerifyTest.BesideBrokenPolicyTest"))

      write(
        dir,
        "broken_policy_test.exs",
        "defmodule VerifyTest.BrokenBeside do\n  use AshGrant.PolicyTest\n"
      )

      assert {:error, output, 2} = Verify.run_cli([dir])
      assert output =~ "1 test(s) passed, 1 error(s)"
      assert output =~ "broken_policy_test.exs"
    end
  end

  describe "output" do
    test "--verbose lists each test" do
      assert {:ok, output, 0} = Verify.run_cli([@fixture_path, "--verbose"])
      assert output =~ "✓ admin can read"
    end

    @tag :tmp_dir
    test "--format json reports files that failed to load", %{tmp_dir: dir} do
      File.cp!(@fixture_path, Path.join(dir, "document.yaml"))
      broken = write(dir, "broken.yaml", "tests: [unclosed\n")

      assert {:error, output, 2} = Verify.run_cli([dir, "--format", "json"])

      assert %{"passed" => passed, "failed" => 0, "errors" => [error]} = Jason.decode!(output)
      assert passed > 0
      assert error["path"] == broken
      assert is_binary(error["message"])
    end
  end
end

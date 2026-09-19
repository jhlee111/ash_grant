defmodule Mix.Tasks.AshGrant.CheckPermissionsTest do
  @moduledoc """
  Tests for the `mix ash_grant.check_permissions` task (issue #162).

  Like the other task tests, these call `run_cli/2` directly to avoid
  `Mix.Task.run("app.start")` and shell side effects.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshGrant.CheckPermissions

  @moduletag :tmp_dir

  @check_opts [resources: [AshGrant.Test.Post]]

  defp write(tmp_dir, name, content) do
    path = Path.join(tmp_dir, name)
    File.write!(path, content)
    path
  end

  describe "exit code" do
    test "0 when every string checks out", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read:always\npost:*:update:own\n")

      assert {:ok, output, 0} = CheckPermissions.run_cli([path], @check_opts)
      assert output =~ "Checked 2 permission(s): 0 error(s), 0 warning(s)."
    end

    test "0 for warnings only, which are still printed", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read*:always\n")

      assert {:ok, output, 0} = CheckPermissions.run_cli([path], @check_opts)
      assert output =~ "post:*:read*:always"
      assert output =~ "warning:"
      assert output =~ "0 error(s), 1 warning(s)"
    end

    test "1 when any string has an error", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read:always\npost:*:read:owm\n")

      assert {:error, output, 1} = CheckPermissions.run_cli([path], @check_opts)
      assert output =~ "post:*:read:owm"
      assert output =~ "error: Scope `owm` is not declared"
      assert output =~ "1 error(s), 0 warning(s)"
      # Clean strings are not listed.
      refute output =~ "post:*:read:always\n"
    end
  end

  describe "input" do
    test "a newline list skips blank lines and # comments", %{tmp_dir: tmp_dir} do
      path =
        write(tmp_dir, "grants.txt", "# editor\n\npost:*:read:always\r\n  post:*:update:own  \n")

      assert {:ok, output, 0} = CheckPermissions.run_cli([path], @check_opts)
      assert output =~ "Checked 2 permission(s)"
    end

    test "a JSON array of strings", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.json", ~s(["post:*:read:always", "post:*:reed:always"]))

      assert {:error, output, 1} = CheckPermissions.run_cli([path], @check_opts)
      assert output =~ "post:*:reed:always"
    end

    test "a JSON object labels each finding with its key", %{tmp_dir: tmp_dir} do
      path =
        write(
          tmp_dir,
          "roles.json",
          ~s({"admin": ["post:*:*:always"], "editor": ["post:*:read:owm"]})
        )

      assert {:error, output, 1} = CheckPermissions.run_cli([path], @check_opts)
      assert output =~ "post:*:read:owm (editor)"
      assert output =~ "Checked 2 permission(s)"
    end

    test "--otp-app reads that application's ash_domains", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read:always\nemployee:*:read:org_self\n")

      assert {:ok, _output, 0} = CheckPermissions.run_cli([path, "--otp-app", "ash_grant"])
    end
  end

  describe "--format json" do
    test "is machine-readable and lists only strings with issues", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read:always\npost:*:read:owm\n")

      assert {:error, output, 1} =
               CheckPermissions.run_cli([path, "--format", "json"], @check_opts)

      assert %{
               "checked" => 2,
               "errors" => 1,
               "warnings" => 0,
               "results" => [
                 %{
                   "permission" => "post:*:read:owm",
                   "issues" => [
                     %{
                       "code" => "undeclared_scope",
                       "severity" => "error",
                       "segment" => "scope",
                       "resources" => ["AshGrant.Test.Post"]
                     }
                   ]
                 }
               ]
             } = Jason.decode!(output)
    end
  end

  describe "usage errors exit 2" do
    test "no file" do
      assert {:error, output, 2} = CheckPermissions.run_cli([])
      assert output =~ "Usage:"
    end

    test "a file that does not exist" do
      assert {:error, output, 2} = CheckPermissions.run_cli(["/nonexistent/grants.txt"])
      assert output =~ "Cannot read"
    end

    test "no AshGrant resources to check against", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read:always\n")

      assert {:error, output, 2} = CheckPermissions.run_cli([path, "--otp-app", "stream_data"])
      assert output =~ "No AshGrant resources found in :stream_data's :ash_domains"
    end

    test "an unknown option", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read:always\n")

      assert {:error, output, 2} = CheckPermissions.run_cli([path, "--bogus"])
      assert output =~ "Invalid options"
    end

    test "an unknown format", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "grants.txt", "post:*:read:always\n")

      assert {:error, _output, 2} = CheckPermissions.run_cli([path, "--format", "xml"])
    end

    test "JSON that is not a list of strings", %{tmp_dir: tmp_dir} do
      assert {:error, _, 2} = CheckPermissions.run_cli([write(tmp_dir, "a.json", "[1, 2]")])
      assert {:error, _, 2} = CheckPermissions.run_cli([write(tmp_dir, "b.json", ~s("x"))])
      assert {:error, _, 2} = CheckPermissions.run_cli([write(tmp_dir, "c.json", "{nope")])
    end
  end
end

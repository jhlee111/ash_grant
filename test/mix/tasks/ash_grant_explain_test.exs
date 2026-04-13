defmodule Mix.Tasks.AshGrant.ExplainTest do
  @moduledoc """
  Tests for the `mix ash_grant.explain` task.

  The task itself is a thin wrapper that calls `run_cli/1`. We test the
  wrapper function directly to avoid triggering `Mix.Task.run("app.start")`
  and shell side effects — all assertions operate on the structured
  `{status, output, exit_code}` tuple it returns.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshGrant.Explain

  describe "run_cli/1 — happy paths" do
    test "returns :ok with text output for an allowed action" do
      assert {:ok, output, 0} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "read"
               ])

      assert is_binary(output)
      assert output =~ "allow"
      assert output =~ "id_loadable_post"
      assert output =~ "read"
    end

    test "returns :ok with text output for a denied action" do
      assert {:ok, output, 0} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "update"
               ])

      assert is_binary(output)
      assert output =~ ~r/deny|denied/i
    end

    test "returns valid JSON when --format json is given" do
      assert {:ok, output, 0} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "read",
                 "--format",
                 "json"
               ])

      assert {:ok, decoded} = Jason.decode(output)
      assert decoded["decision"] == "allow"
      assert decoded["action"] == "read"
      assert is_binary(decoded["summary"])
      assert decoded["reason_code"] == "allow_matched"
    end

    test "accepts --context as JSON and forwards it to the resolver" do
      # Context has no effect for this actor's permissions, but parsing
      # must succeed and the task must still return {:ok, ...}.
      assert {:ok, _output, 0} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "read",
                 "--context",
                 ~s({"reference_date":"2024-01-01"})
               ])
    end
  end

  describe "run_cli/1 — error handling" do
    test "returns :error with exit code 1 for an unknown resource" do
      assert {:error, output, 1} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "definitely_not_a_resource",
                 "--action",
                 "read"
               ])

      assert output =~ "unknown_resource" or output =~ "not found"
    end

    test "returns :error with exit code 1 when the actor cannot be loaded" do
      assert {:error, output, 1} =
               Explain.run_cli([
                 "--actor",
                 "missing_user",
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "read"
               ])

      assert output =~ "actor_not_found" or output =~ ~r/actor.*not.*found/i
    end

    test "returns :error with exit code 1 when resolver has no load_actor/1" do
      assert {:error, output, 1} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "no_load_actor_post",
                 "--action",
                 "read"
               ])

      assert output =~ "load_actor" or output =~ "not_implemented"
    end

    test "returns :error with exit code 2 when --actor is missing" do
      assert {:error, output, 2} =
               Explain.run_cli([
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "read"
               ])

      assert output =~ "--actor"
    end

    test "returns :error with exit code 2 when --resource is missing" do
      assert {:error, output, 2} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--action",
                 "read"
               ])

      assert output =~ "--resource"
    end

    test "returns :error with exit code 2 when --action is missing" do
      assert {:error, output, 2} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "id_loadable_post"
               ])

      assert output =~ "--action"
    end

    test "returns :error with exit code 2 when --context is not valid JSON" do
      assert {:error, output, 2} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "read",
                 "--context",
                 "not-json"
               ])

      assert output =~ ~r/context/i
    end

    test "returns :error with exit code 2 when --format is unknown" do
      assert {:error, output, 2} =
               Explain.run_cli([
                 "--actor",
                 "user_1",
                 "--resource",
                 "id_loadable_post",
                 "--action",
                 "read",
                 "--format",
                 "yaml"
               ])

      assert output =~ ~r/format/i
    end
  end
end

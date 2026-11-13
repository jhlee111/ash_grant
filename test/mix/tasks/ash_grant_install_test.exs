defmodule Mix.Tasks.AshGrant.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "imports the ash_grant formatter rules" do
    test_project()
    |> Igniter.compose_task("ash_grant.install", [])
    |> assert_has_patch(".formatter.exs", """
    + |  import_deps: [:ash_grant]
    """)
  end
end

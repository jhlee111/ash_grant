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

  test "puts ash_grant first in the resource and domain section order" do
    test_project()
    |> Igniter.compose_task("ash_grant.install", [])
    |> assert_creates("config/config.exs", """
    import Config

    config :spark,
      formatter: [
        "Ash.Resource": [section_order: [:ash_grant]],
        "Ash.Domain": [section_order: [:ash_grant]]
      ]
    """)
  end
end

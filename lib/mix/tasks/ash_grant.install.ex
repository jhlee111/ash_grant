if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshGrant.Install do
    @shortdoc "Installs AshGrant into a project. Should be called with `mix igniter.install ash_grant`."

    @moduledoc """
    #{@shortdoc}

    Imports the `ash_grant` formatter rules, so `mix format` leaves the DSL unparenthesised.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        installs: [{:ash, "~> 3.33"}],
        example: "mix igniter.install ash_grant"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_grant)
      |> Igniter.add_notice("""
      AshGrant installed.

      Next, add `extensions: [AshGrant]` to a resource and declare a resolver
      and scopes in its `ash_grant` block:
      https://hexdocs.pm/ash_grant/readme.html#quick-start
      """)
    end
  end
else
  defmodule Mix.Tasks.AshGrant.Install do
    @shortdoc "Installs AshGrant into a project. Should be called with `mix igniter.install ash_grant`."

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_grant.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end

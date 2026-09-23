defmodule AshGrant.Verifiers.ValidateArgumentResolvers do
  @moduledoc """
  Spark DSL verifier that checks each `resolve_argument` declaration is actually
  referenced by at least one scope, domain-aware.

  `AshGrant.Transformers.AddArgumentResolvers` cannot read domain-inherited
  scopes without re-opening the compile cycle fixed in v0.20 (a domain with a
  `code_interface` entry deadlocks), so it defers this check when the resource
  sits on a domain. This verifier runs post-compile, where the domain is safe
  to read, and reports a compile warning (verifier errors surface as warnings)
  for a `resolve_argument` that no scope references — including when the only
  candidate was a domain scope that does not actually exist (#147).
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  @spec verify(dsl_state :: map()) :: :ok | {:error, Spark.Error.DslError.t()}
  def verify(dsl_state) do
    declarations =
      dsl_state
      |> Verifier.get_entities([:ash_grant])
      |> Enum.filter(&match?(%AshGrant.Dsl.ResolveArgument{}, &1))

    case declarations do
      [] ->
        :ok

      declarations ->
        resource = Verifier.get_persisted(dsl_state, :module)
        arg_map = AshGrant.ArgumentAnalyzer.arg_to_scopes(resource)
        validate_declarations(declarations, arg_map, resource)
    end
  end

  defp validate_declarations(declarations, arg_map, resource) do
    Enum.reduce_while(declarations, :ok, fn decl, :ok ->
      case unreferenced_error(decl.name, arg_map, resource) do
        nil -> {:cont, :ok}
        error -> {:halt, {:error, error}}
      end
    end)
  end

  defp unreferenced_error(name, arg_map, resource) do
    if Map.has_key?(arg_map, name) and arg_map[name] != [] do
      nil
    else
      Spark.Error.DslError.exception(
        module: resource,
        path: [:ash_grant, :resolve_argument, name],
        message: """
        resolve_argument :#{name} is declared but no scope references ^arg(:#{name}).

        Either add an expression like `expr(^arg(:#{name}) == some_attribute)` to at
        least one scope, or remove this declaration.
        """
      )
    end
  end
end

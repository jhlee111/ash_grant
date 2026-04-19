defmodule AshGrant.Verifiers.ValidateResolverPresent do
  @moduledoc """
  Spark DSL verifier that warns at compile time when neither the resource nor
  its domain defines a resolver.

  ## Why a verifier (warning) and not a transformer (error)?

  Reading the domain's DSL from a resource transformer creates a compile-time
  cycle when the domain also has `code_interface` entries: the resource needs
  the domain compiled to read its config, and the domain needs the resource
  compiled to wire the code_interface. A verifier runs after the module is
  compiled so it can safely reach into the domain without the cycle.

  Spark converts verifier errors to compile warnings (see
  `Spark.Dsl.Verifier` and the `catch` in `Spark.Dsl.__verify_spark_dsl__/1`),
  so this check cannot fail the build — the compile warning surfaces during
  `mix compile`, and a runtime guard in `AshGrant.Check.resolve_permissions/3`
  raises a clear error if authorization is attempted without a resolver.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  @spec verify(dsl_state :: map()) :: :ok | {:error, Spark.Error.DslError.t()}
  def verify(dsl_state) do
    if resolver_present?(dsl_state) do
      :ok
    else
      resource = Verifier.get_persisted(dsl_state, :module)

      {:error,
       Spark.Error.DslError.exception(
         module: resource,
         path: [:ash_grant, :resolver],
         message: """
         No resolver configured for #{inspect(resource)}.

         Either set a resolver on the resource:

             ash_grant do
               resolver MyApp.PermissionResolver
             end

         Or set one on the domain using the AshGrant.Domain extension:

             use Ash.Domain, extensions: [AshGrant.Domain]

             ash_grant do
               resolver MyApp.PermissionResolver
             end
         """
       )}
    end
  end

  @spec resolver_present?(dsl_state :: map()) :: boolean()
  defp resolver_present?(dsl_state) do
    Verifier.get_option(dsl_state, [:ash_grant], :resolver) != nil or
      domain_resolver_present?(dsl_state)
  end

  @spec domain_resolver_present?(dsl_state :: map()) :: boolean()
  defp domain_resolver_present?(dsl_state) do
    case Verifier.get_persisted(dsl_state, :domain) do
      nil -> false
      domain -> AshGrant.Domain.Info.resolver(domain) != nil
    end
  end
end

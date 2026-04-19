defmodule AshGrant.Verifiers.ValidateScopes do
  @moduledoc """
  Spark DSL verifier that emits helpful warnings for common scope
  configuration issues:

  - Warns if `:all` scope is not defined on the resource or its domain
  - Warns about deprecated `owner_field` and `scope_resolver` usage

  Implemented as a verifier so that it can safely reach into the resource's
  domain (via `AshGrant.Domain.Info`) without risking the compile-time cycle
  that a transformer would trigger when the domain has `code_interface`
  entries.

  ## See Also

  - `AshGrant.Dsl` - DSL definition with scope entity and `write:` option
  - `AshGrant.Info` - Runtime introspection for scopes
  - `AshGrant.Check` - Write action check with DB query fallback for relational scopes
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  @spec verify(dsl_state :: map()) :: :ok
  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    if resolver_configured?(dsl_state) do
      validate_common_scopes(dsl_state, resource)
      validate_deprecated_options(dsl_state, resource)
    end

    :ok
  end

  @spec resolver_configured?(dsl_state :: map()) :: boolean()
  defp resolver_configured?(dsl_state) do
    Verifier.get_option(dsl_state, [:ash_grant], :resolver) != nil or
      case Verifier.get_persisted(dsl_state, :domain) do
        nil -> false
        domain -> AshGrant.Domain.Info.resolver(domain) != nil
      end
  end

  @spec validate_common_scopes(dsl_state :: map(), resource :: module()) :: :ok
  defp validate_common_scopes(dsl_state, resource) do
    scope_names = scope_names_for(dsl_state)

    unless :all in scope_names do
      IO.warn(
        """
        AshGrant: scope :all is not defined in #{inspect(resource)}.
        Consider adding: scope :all, true

        This scope is commonly used for permissions like "#{derive_resource_name(resource)}:*:read:all"
        """,
        []
      )
    end

    :ok
  end

  @spec scope_names_for(dsl_state :: map()) :: [atom()]
  defp scope_names_for(dsl_state) do
    resource_names = scope_entities(dsl_state) |> Enum.map(& &1.name)

    domain_names =
      case Verifier.get_persisted(dsl_state, :domain) do
        nil -> []
        domain -> AshGrant.Domain.Info.scopes(domain) |> Enum.map(& &1.name)
      end

    Enum.uniq(resource_names ++ domain_names)
  end

  @spec validate_deprecated_options(dsl_state :: map(), resource :: module()) :: :ok
  defp validate_deprecated_options(dsl_state, resource) do
    if owner_field = Verifier.get_option(dsl_state, [:ash_grant], :owner_field) do
      IO.warn(
        """
        AshGrant: owner_field is deprecated in #{inspect(resource)}.

        Replace:
            owner_field #{inspect(owner_field)}

        With:
            scope :own, expr(#{owner_field} == ^actor(:id))

        The owner_field option will be removed in v1.0.0.
        """,
        []
      )
    end

    if Verifier.get_option(dsl_state, [:ash_grant], :scope_resolver) do
      IO.warn(
        """
        AshGrant: scope_resolver is deprecated in #{inspect(resource)}.

        Migrate your scopes to inline definitions:
            scope :scope_name, expr(your_filter_expression)

        The scope_resolver option will be removed in a future version.
        """,
        []
      )
    end

    :ok
  end

  @spec scope_entities(dsl_state :: map()) :: [AshGrant.Dsl.Scope.t()]
  defp scope_entities(dsl_state) do
    Verifier.get_entities(dsl_state, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.Scope{}, &1))
  end

  @spec derive_resource_name(resource :: module()) :: String.t()
  defp derive_resource_name(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end

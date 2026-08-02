defmodule AshGrant.Verifiers.ValidateScopes do
  @moduledoc """
  Spark DSL verifier that validates scope-adjacent configuration:

  - Warns about deprecated `owner_field` and `scope_resolver` usage
  - Raises a DslError if `instance_key` does not exist as an attribute

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
  @spec verify(dsl_state :: map()) :: :ok | {:error, Spark.Error.DslError.t()}
  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    if resolver_configured?(dsl_state) do
      validate_deprecated_options(dsl_state, resource)
      validate_instance_key(dsl_state, resource)
    else
      :ok
    end
  end

  @spec resolver_configured?(dsl_state :: map()) :: boolean()
  defp resolver_configured?(dsl_state) do
    Verifier.get_option(dsl_state, [:ash_grant], :resolver) != nil or
      case Verifier.get_persisted(dsl_state, :domain) do
        nil -> false
        domain -> AshGrant.Domain.Info.resolver(domain) != nil
      end
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

  @spec validate_instance_key(dsl_state :: map(), resource :: module()) ::
          :ok | {:error, Spark.Error.DslError.t()}
  defp validate_instance_key(dsl_state, resource) do
    instance_key = Verifier.get_option(dsl_state, [:ash_grant], :instance_key)

    if instance_key && instance_key != :id do
      attributes = Verifier.get_entities(dsl_state, [:attributes])
      attr_names = Enum.map(attributes, & &1.name)

      if instance_key in attr_names do
        :ok
      else
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:ash_grant, :instance_key],
           message:
             "instance_key :#{instance_key} does not exist as an attribute on #{inspect(resource)}. " <>
               "Available attributes: #{inspect(attr_names)}"
         )}
      end
    else
      :ok
    end
  end
end

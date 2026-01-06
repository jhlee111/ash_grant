defmodule AshGrant.Transformers.ValidateScopes do
  @moduledoc """
  Spark DSL transformer that validates scope definitions at compile time.

  This transformer provides helpful warnings for common scope configuration issues:

  - Warns if `:all` scope is commonly expected but not defined
  - Warns about deprecated `owner_field` usage

  ## Example Warnings

  When no `:all` scope is defined:

      warning: AshGrant: scope :all is not defined in MyApp.Blog.Post.
      Consider adding: scope :all, true
      This scope is commonly used for permissions like "post:*:read:all"

  ## See Also

  - `AshGrant.Dsl` - DSL definition with scope entity
  - `AshGrant.Info` - Runtime introspection for scopes
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :module)

    # Only validate if ash_grant is configured
    resolver = Transformer.get_option(dsl_state, [:ash_grant], :resolver)

    if resolver do
      validate_common_scopes(dsl_state, resource)
      validate_deprecated_options(dsl_state, resource)
    end

    {:ok, dsl_state}
  end

  defp validate_common_scopes(dsl_state, resource) do
    scopes = get_scope_entities(dsl_state)
    scope_names = Enum.map(scopes, & &1.name)

    # Warn if :all scope is missing - it's commonly expected
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
  end

  defp validate_deprecated_options(dsl_state, resource) do
    # Check for deprecated owner_field
    owner_field = Transformer.get_option(dsl_state, [:ash_grant], :owner_field)

    if owner_field do
      IO.warn(
        """
        AshGrant: owner_field is deprecated in #{inspect(resource)}.

        Replace:
            owner_field #{inspect(owner_field)}

        With:
            scope :own, expr(#{owner_field} == ^actor(:id))

        The owner_field option will be removed in v0.3.0.
        """,
        []
      )
    end

    # Check for deprecated scope_resolver
    scope_resolver = Transformer.get_option(dsl_state, [:ash_grant], :scope_resolver)

    if scope_resolver do
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
  end

  defp get_scope_entities(dsl_state) do
    Transformer.get_entities(dsl_state, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.Scope{}, &1))
  end

  defp derive_resource_name(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end

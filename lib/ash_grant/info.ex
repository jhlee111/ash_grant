defmodule AshGrant.Info do
  @moduledoc """
  Introspection helpers for AshGrant DSL configuration.
  """

  use Spark.InfoGenerator, extension: AshGrant, sections: [:ash_grant]

  require Ash.Expr

  @doc """
  Gets the permission resolver for a resource.
  """
  @spec resolver(Ash.Resource.t()) :: module() | function() | nil
  def resolver(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :resolver)
  end

  @doc """
  Gets the scope resolver for a resource.

  DEPRECATED: Use inline `scope` entities instead.
  """
  @spec scope_resolver(Ash.Resource.t()) :: module() | function() | nil
  def scope_resolver(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :scope_resolver)
  end

  @doc """
  Gets the resource name for permission matching.

  Falls back to deriving from the module name if not configured.
  """
  @spec resource_name(Ash.Resource.t()) :: String.t()
  def resource_name(resource) do
    case Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :resource_name) do
      nil -> derive_resource_name(resource)
      name -> name
    end
  end

  @doc """
  Gets the owner field for "own" scope resolution.
  """
  @spec owner_field(Ash.Resource.t()) :: atom() | nil
  def owner_field(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :owner_field)
  end

  @doc """
  Checks if AshGrant is configured for a resource.
  """
  @spec configured?(Ash.Resource.t()) :: boolean()
  def configured?(resource) do
    resolver(resource) != nil
  end

  @doc """
  Gets all scope definitions for a resource.
  """
  @spec scopes(Ash.Resource.t()) :: [AshGrant.Dsl.Scope.t()]
  def scopes(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.Scope{}, &1))
  end

  @doc """
  Gets a specific scope by name.
  """
  @spec get_scope(Ash.Resource.t(), atom()) :: AshGrant.Dsl.Scope.t() | nil
  def get_scope(resource, name) do
    scopes(resource)
    |> Enum.find(&(&1.name == name))
  end

  @doc """
  Resolves a scope to its filter expression.

  If the scope has inheritance, the parent scopes are combined with AND.
  Returns `false` for unknown scopes.
  """
  @spec resolve_scope_filter(Ash.Resource.t(), atom(), map()) :: boolean() | Ash.Expr.t()
  def resolve_scope_filter(resource, scope_name, context) do
    case get_scope(resource, scope_name) do
      nil ->
        # Check for legacy scope_resolver
        case scope_resolver(resource) do
          nil -> false
          resolver -> resolve_with_legacy_resolver(resolver, to_string(scope_name), context)
        end

      scope ->
        resolve_scope_with_inheritance(resource, scope, context)
    end
  end

  # Private functions

  defp derive_resource_name(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp resolve_with_legacy_resolver(resolver, scope, context) when is_function(resolver, 2) do
    resolver.(scope, context)
  end

  defp resolve_with_legacy_resolver(resolver, scope, context) when is_atom(resolver) do
    resolver.resolve(scope, context)
  end

  defp resolve_scope_with_inheritance(resource, scope, context) do
    # First, get the base filter for this scope
    base_filter = scope.filter

    # If there's inheritance, combine with parent scope(s)
    case scope.inherits do
      nil ->
        base_filter

      [] ->
        base_filter

      parent_names when is_list(parent_names) ->
        parent_filters =
          parent_names
          |> Enum.map(&resolve_scope_filter(resource, &1, context))
          |> Enum.reject(&(&1 == true))

        case {parent_filters, base_filter} do
          {[], filter} ->
            filter

          {filters, true} ->
            combine_filters_with_and(filters)

          {filters, filter} ->
            combine_filters_with_and(filters ++ [filter])
        end
    end
  end

  defp combine_filters_with_and([single]), do: single

  defp combine_filters_with_and([first | rest]) do
    Enum.reduce(rest, first, fn filter, acc ->
      Ash.Expr.expr(^acc and ^filter)
    end)
  end
end

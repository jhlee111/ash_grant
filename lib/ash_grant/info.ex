defmodule AshGrant.Info do
  @moduledoc """
  Introspection helpers for AshGrant DSL configuration.

  This module provides functions to query AshGrant configuration at runtime,
  including resolvers, scopes, field groups, and policy settings.

  ## Common Functions

  | Function | Description |
  |----------|-------------|
  | `resolver/1` | Get the permission resolver for a resource |
  | `default_policies/1` | Get the default_policies setting |
  | `default_field_policies/1` | Get the default_field_policies setting |
  | `resource_name/1` | Get the resource name for permission matching |
  | `scopes/1` | Get all scope definitions |
  | `get_scope/2` | Get a specific scope by name |
  | `resolve_scope_filter/3` | Resolve a scope to its read filter expression |
  | `resolve_write_scope_filter/3` | Resolve a scope to its write filter expression |
  | `field_groups/1` | Get all field group definitions |
  | `get_field_group/2` | Get a specific field group by name |
  | `resolve_field_group/2` | Resolve a field group with inheritance |
  | `owner_field/1` | **Deprecated.** Use explicit scope expressions instead |

  ## Example

      iex> AshGrant.Info.default_policies(MyApp.Blog.Post)
      true

      iex> AshGrant.Info.resolver(MyApp.Blog.Post)
      MyApp.PermissionResolver

      iex> AshGrant.Info.scopes(MyApp.Blog.Post) |> Enum.map(& &1.name)
      [:all, :own, :published]
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
  Gets the field to match instance permission IDs against.

  Defaults to `:id` (primary key) when not configured.
  """
  @spec instance_key(Ash.Resource.t()) :: atom()
  def instance_key(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :instance_key) || :id
  end

  @doc """
  Gets all scope_through entities for a resource.

  Returns an empty list if none are configured.
  """
  @spec scope_throughs(Ash.Resource.t()) :: [AshGrant.Dsl.ScopeThrough.t()]
  def scope_throughs(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.ScopeThrough{}, &1))
  end

  @doc """
  Gets the owner field for "own" scope resolution.

  DEPRECATED: Use explicit `scope :own, expr(field == ^actor(:id))` instead.
  This option will be removed in v1.0.0.
  """
  @deprecated "Use explicit scope expressions instead of owner_field"
  @spec owner_field(Ash.Resource.t()) :: atom() | nil
  def owner_field(resource) do
    case Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :owner_field) do
      nil ->
        nil

      field ->
        IO.warn(
          "owner_field is deprecated. Use explicit scope expressions instead:\n\n" <>
            "    scope :own, expr(#{field} == ^actor(:id))\n\n" <>
            "This option will be removed in v1.0.0.",
          []
        )

        field
    end
  end

  @doc """
  Gets the default_policies setting.

  Returns `false` if not configured, or one of:
  - `true` or `:all` - Generate policies for both read and write
  - `:read` - Only generate read policy
  - `:write` - Only generate write policy
  """
  @spec default_policies(Ash.Resource.t()) :: boolean() | :read | :write | :all
  def default_policies(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :default_policies, false)
  end

  @doc """
  Gets the list of action names configured via `can_perform_actions`.

  Returns an empty list if not configured.
  """
  @spec can_perform_actions(Ash.Resource.t()) :: [atom()]
  def can_perform_actions(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :can_perform_actions) || []
  end

  @doc """
  Gets the default_field_policies setting.

  Returns `true` if field policies should be auto-generated from field_group definitions,
  or `false` (default) if field policies should be manually defined.
  """
  @spec default_field_policies(Ash.Resource.t()) :: boolean()
  def default_field_policies(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_grant], :default_field_policies, false)
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
  Gets all `resolve_argument` declarations for a resource.
  """
  @spec resolve_arguments(Ash.Resource.t()) :: [AshGrant.Dsl.ResolveArgument.t()]
  def resolve_arguments(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.ResolveArgument{}, &1))
  end

  @doc """
  Gets all field group definitions for a resource.
  """
  @spec field_groups(Ash.Resource.t()) :: [AshGrant.Dsl.FieldGroup.t()]
  def field_groups(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.FieldGroup{}, &1))
  end

  @doc """
  Gets a specific field group by name.
  """
  @spec get_field_group(Ash.Resource.t(), atom()) :: AshGrant.Dsl.FieldGroup.t() | nil
  def get_field_group(resource, name) do
    field_groups(resource)
    |> Enum.find(&(&1.name == name))
  end

  @doc """
  Gets the description for a specific scope.

  Returns `nil` if the scope doesn't exist or has no description.

  ## Examples

      iex> AshGrant.Info.scope_description(MyApp.Blog.Post, :own)
      "Records owned by the current user"

      iex> AshGrant.Info.scope_description(MyApp.Blog.Post, :all)
      nil
  """
  @spec scope_description(Ash.Resource.t(), atom()) :: String.t() | nil
  def scope_description(resource, name) do
    case get_scope(resource, name) do
      nil -> nil
      scope -> scope.description
    end
  end

  @doc """
  Resolves a scope to its read filter expression.

  Uses the scope's `filter` field (ignoring any `write:` option).
  If the scope has inheritance, the parent scopes are combined with AND.
  Returns `false` for unknown scopes.

  For write action scope resolution, use `resolve_write_scope_filter/3` instead.
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

  @doc """
  Resolves a scope's write filter expression.

  If the scope has a `write` field set, uses that value. Otherwise falls back
  to the regular `filter`. This ensures write actions use a direct-field expression
  when relationship traversal (exists/dot-paths) cannot be evaluated in-memory.

  Returns `false` for unknown scopes, or when `write: false` is explicitly set.

  ## Resolution Order

  1. If scope has `write:` set → use `write` value (`false`, `true`, or expression)
  2. If scope has no `write:` → fall back to `scope.filter` (backward compatible)
  3. Inheritance: parent `write:` values are resolved recursively and combined with AND
  4. If any parent returns `false` → short-circuit to `false` (deny propagation)

  ## Examples

      # Scope with write: expr(...) → returns the write expression
      resolve_write_scope_filter(Resource, :same_org, context)
      # => expr(org_id == ^actor(:org_id))

      # Scope with write: false → returns false
      resolve_write_scope_filter(Resource, :readonly, context)
      # => false

      # Scope without write: → falls back to filter
      resolve_write_scope_filter(Resource, :own, context)
      # => expr(author_id == ^actor(:id))
  """
  @spec resolve_write_scope_filter(Ash.Resource.t(), atom(), map()) :: boolean() | Ash.Expr.t()
  def resolve_write_scope_filter(resource, scope_name, context) do
    case get_scope(resource, scope_name) do
      nil ->
        case scope_resolver(resource) do
          nil -> false
          resolver -> resolve_with_legacy_resolver(resolver, to_string(scope_name), context)
        end

      scope ->
        resolve_write_scope_with_inheritance(resource, scope, context)
    end
  end

  @doc """
  Resolves a field group to its complete field set including inherited fields.

  Returns a map with:
  - `:fields` - Complete list of accessible field atoms (union of own + inherited)
  - `:masked_fields` - Map of field_name => mask_function for fields masked at THIS level only

  Masking is NOT inherited. A higher-level field group sees original values
  unless it explicitly declares its own masking.

  Returns nil if the field group does not exist.
  """
  @spec resolve_field_group(Ash.Resource.t(), atom()) ::
          %{fields: [atom()], masked_fields: map()} | nil
  def resolve_field_group(resource, field_group_name) do
    case get_field_group(resource, field_group_name) do
      nil -> nil
      fg -> do_resolve_field_group(resource, fg)
    end
  end

  # Private functions

  defp do_resolve_field_group(resource, fg) do
    inherited_fields = resolve_inherited_fields(resource, fg.inherits)
    all_fields = Enum.uniq(inherited_fields ++ (fg.fields || []))
    masked_fields = build_masked_fields(fg.mask, fg.mask_with, all_fields)

    %{fields: all_fields, masked_fields: masked_fields}
  end

  defp resolve_inherited_fields(_resource, nil), do: []
  defp resolve_inherited_fields(_resource, []), do: []

  defp resolve_inherited_fields(resource, parents) do
    Enum.flat_map(parents, fn parent_name ->
      case resolve_field_group(resource, parent_name) do
        nil -> []
        resolved -> resolved.fields
      end
    end)
  end

  defp build_masked_fields(nil, _mask_fn, _all_fields), do: %{}
  defp build_masked_fields(_mask_fields, nil, _all_fields), do: %{}

  defp build_masked_fields(mask_fields, mask_fn, all_fields) do
    mask_fields
    |> Enum.filter(&(&1 in all_fields))
    |> Map.new(&{&1, mask_fn})
  end

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

  defp resolve_write_scope_with_inheritance(resource, scope, context) do
    base_filter = if scope.write == nil, do: scope.filter, else: scope.write

    if base_filter == false do
      false
    else
      resolve_write_parents(resource, scope.inherits, base_filter, context)
    end
  end

  defp resolve_write_parents(_resource, nil, base_filter, _context), do: base_filter
  defp resolve_write_parents(_resource, [], base_filter, _context), do: base_filter

  defp resolve_write_parents(resource, parent_names, base_filter, context) do
    parent_filters = Enum.map(parent_names, &resolve_write_scope_filter(resource, &1, context))

    if Enum.any?(parent_filters, &(&1 == false)) do
      false
    else
      merge_parent_and_base_filters(parent_filters, base_filter)
    end
  end

  defp merge_parent_and_base_filters(parent_filters, base_filter) do
    non_true_filters = Enum.reject(parent_filters, &(&1 == true))

    case {non_true_filters, base_filter} do
      {[], filter} -> filter
      {filters, true} -> combine_filters_with_and(filters)
      {filters, filter} -> combine_filters_with_and(filters ++ [filter])
    end
  end

  defp combine_filters_with_and([single]), do: single

  defp combine_filters_with_and([first | rest]) do
    Enum.reduce(rest, first, fn filter, acc ->
      Ash.Expr.expr(^acc and ^filter)
    end)
  end
end

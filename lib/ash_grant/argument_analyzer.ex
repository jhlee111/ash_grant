defmodule AshGrant.ArgumentAnalyzer do
  @moduledoc """
  Compile-time analysis of which scopes reference which `^arg(...)` templates.

  Given a resource, walks every scope's resolved (inheritance-applied) filter
  expression and records the set of `{:_arg, name}` references per scope.
  Inverting that mapping produces `%{arg_name => [scope_atoms]}`, which the
  `AshGrant.Transformers.AddArgumentResolvers` transformer uses to wire up
  `AshGrant.Changes.ResolveArgument` only where the argument is actually needed.

  The walker understands the same AST shapes as
  `AshGrant.Check.contains_relationship_reference?/1`:

    * `%Ash.Query.BooleanExpression{}`, `%Ash.Query.Not{}`
    * `%Ash.Query.Call{args: [...]}`
    * `%Ash.Query.Exists{expr: ...}`
    * `%Ash.Query.Ref{}`
    * structs with `__function__?: true` and `:arguments`
    * structs with `__operator__?: true` / `:left` + `:right`
    * lists (for `in` operator RHS and function arg collections)
    * bare `{:_arg, name}` template tuples
  """

  alias AshGrant.Info

  @type scope_name :: atom()
  @type arg_name :: atom()

  @doc """
  Returns `%{arg_name => [scope_names]}` for all args referenced by any scope
  on the given resource. Uses write-scope resolution so inheritance is applied.
  """
  @spec arg_to_scopes(Ash.Resource.t()) :: %{arg_name() => [scope_name()]}
  def arg_to_scopes(resource) do
    resource
    |> Info.scopes()
    |> Enum.reduce(%{}, fn scope, acc ->
      filter = safe_resolve(resource, scope.name)
      args = referenced_args(filter)

      Enum.reduce(args, acc, fn arg, inner ->
        Map.update(inner, arg, [scope.name], &Enum.uniq([scope.name | &1]))
      end)
    end)
  end

  @doc """
  Returns the list of `{:_arg, name}` argument names referenced anywhere in the
  expression.
  """
  @spec referenced_args(any()) :: [arg_name()]
  def referenced_args(expr) do
    expr
    |> walk_args()
    |> Enum.uniq()
  end

  @doc """
  True iff the expression references `{:_arg, name}` anywhere.
  """
  @spec references_arg?(any(), arg_name()) :: boolean()
  def references_arg?(expr, name) do
    name in referenced_args(expr)
  end

  # --- internals -----------------------------------------------------------

  defp safe_resolve(resource, name) do
    Info.resolve_write_scope_filter(resource, name, %{})
  rescue
    _ -> nil
  end

  defp walk_args(true), do: []
  defp walk_args(false), do: []
  defp walk_args(nil), do: []
  defp walk_args({:_arg, name}) when is_atom(name), do: [name]

  defp walk_args(%Ash.Query.BooleanExpression{left: l, right: r}),
    do: walk_args(l) ++ walk_args(r)

  defp walk_args(%Ash.Query.Not{expression: e}), do: walk_args(e)

  defp walk_args(%Ash.Query.Call{args: args}) when is_list(args),
    do: Enum.flat_map(args, &walk_args/1)

  defp walk_args(%Ash.Query.Exists{expr: e}), do: walk_args(e)

  defp walk_args(%Ash.Query.Ref{}), do: []

  defp walk_args(%{__function__?: true, arguments: args}) when is_list(args),
    do: Enum.flat_map(args, &walk_args/1)

  defp walk_args(%{__struct__: _, left: l, right: r}),
    do: walk_args(l) ++ walk_args(r)

  defp walk_args(list) when is_list(list), do: Enum.flat_map(list, &walk_args/1)

  # Generic tuples (including keyword-list entries like {:do, expr}, {:else, expr}).
  # The `{:_arg, name}` case is matched earlier; here we fall through and walk elements.
  defp walk_args(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&walk_args/1)

  defp walk_args(_), do: []
end

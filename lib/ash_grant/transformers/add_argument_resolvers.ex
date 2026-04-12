defmodule AshGrant.Transformers.AddArgumentResolvers do
  @moduledoc """
  Spark DSL transformer that wires up `resolve_argument` declarations.

  For every `resolve_argument :name, from_path: [...]` declaration:

    1. Validates the path at compile time (intermediates are belongs_to, leaf
       is an attribute).
    2. Validates that at least one scope references `^arg(:name)` in its
       resolved filter (rejecting dead declarations).
    3. For every targeted write action (`:create`, `:update`, `:destroy`, or
       the explicit `:for_actions` list), injects:
        * an `argument :name, <type>, allow_nil?: true` with the type inferred
          from the leaf attribute (if the action does not already declare it)
        * a `change {AshGrant.Changes.ResolveArgument, [name:, path:,
          scopes_needing:]}` with `scopes_needing` computed at compile time
  """

  use Spark.Dsl.Transformer

  require Ash.Expr

  alias Spark.Dsl.Transformer
  alias AshGrant.ArgumentAnalyzer

  @write_action_types [:create, :update, :destroy]

  @impl true
  def after?(AshGrant.Transformers.MergeDomainConfig), do: true
  def after?(_), do: false

  @impl true
  def before?(Ash.Policy.Authorizer), do: true
  def before?(AshGrant.Transformers.AddDefaultPolicies), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    resolve_args =
      dsl_state
      |> Transformer.get_entities([:ash_grant])
      |> Enum.filter(&match?(%AshGrant.Dsl.ResolveArgument{}, &1))

    case resolve_args do
      [] ->
        {:ok, dsl_state}

      declarations ->
        resource = Transformer.get_persisted(dsl_state, :module)
        arg_map = build_arg_map(dsl_state)

        Enum.reduce_while(declarations, {:ok, dsl_state}, fn decl, {:ok, state} ->
          with :ok <- validate_referenced_by_scope(decl, arg_map, resource),
               {:ok, leaf_type} <- validate_and_resolve_path(state, decl, resource),
               {:ok, new_state} <-
                 install_on_actions(state, decl, leaf_type, arg_map, resource) do
            {:cont, {:ok, new_state}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  # Compute %{arg_name => [scope_names]} by walking all scope filters in the
  # DSL state (not the compiled resource — it's not compiled yet).
  defp build_arg_map(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.Scope{}, &1))
    |> Enum.reduce(%{}, fn scope, acc ->
      resolved = resolve_scope_in_dsl(dsl_state, scope)
      args = ArgumentAnalyzer.referenced_args(resolved)

      Enum.reduce(args, acc, fn arg, inner ->
        Map.update(inner, arg, [scope.name], &Enum.uniq([scope.name | &1]))
      end)
    end)
  end

  # Resolve a scope's filter with inheritance from the in-progress DSL state.
  defp resolve_scope_in_dsl(dsl_state, %AshGrant.Dsl.Scope{} = scope) do
    base = if scope.write == nil, do: scope.filter, else: scope.write

    case base do
      false ->
        false

      _ ->
        parents = scope.inherits || []

        parent_filters =
          Enum.map(parents, fn parent_name ->
            find_scope(dsl_state, parent_name)
            |> case do
              nil -> true
              parent -> resolve_scope_in_dsl(dsl_state, parent)
            end
          end)

        combine(parent_filters, base)
    end
  end

  defp find_scope(dsl_state, name) do
    dsl_state
    |> Transformer.get_entities([:ash_grant])
    |> Enum.find(&(match?(%AshGrant.Dsl.Scope{}, &1) and &1.name == name))
  end

  defp combine(parent_filters, base) do
    non_true = Enum.reject(parent_filters, &(&1 == true))

    case {non_true, base} do
      {[], filter} -> filter
      {filters, true} -> and_all(filters)
      {filters, filter} -> and_all(filters ++ [filter])
    end
  end

  defp and_all([single]), do: single

  defp and_all([first | rest]) do
    Enum.reduce(rest, first, fn f, acc -> Ash.Expr.expr(^acc and ^f) end)
  end

  defp validate_referenced_by_scope(%{name: name} = decl, arg_map, resource) do
    if Map.has_key?(arg_map, name) and arg_map[name] != [] do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         module: resource,
         path: [:ash_grant, :resolve_argument, name],
         message: """
         resolve_argument :#{name} is declared but no scope references ^arg(:#{name}).

         Either add an expression like `expr(^arg(:#{name}) == some_attribute)` to at
         least one scope, or remove this declaration. Declaration: #{inspect(decl)}
         """
       )}
    end
  end

  defp validate_and_resolve_path(dsl_state, %{name: name, from_path: path}, resource) do
    do_validate_path(dsl_state, resource, path, [], {:dsl, dsl_state, resource}, name)
  end

  defp do_validate_path(_dsl_state, _original_resource, [], _traversed, _cursor, name) do
    {:error,
     Spark.Error.DslError.exception(
       path: [:ash_grant, :resolve_argument, name],
       message: "resolve_argument :#{name} requires a non-empty from_path"
     )}
  end

  defp do_validate_path(dsl_state, original_resource, [leaf], traversed, cursor, name) do
    case lookup_relationship(cursor, leaf) do
      {:ok, _rel} ->
        {:error,
         Spark.Error.DslError.exception(
           module: original_resource,
           path: [:ash_grant, :resolve_argument, name],
           message: """
           resolve_argument :#{name} — path #{inspect(traversed ++ [leaf])} ends on a
           relationship (:#{leaf}). The final path segment must be an attribute, not
           a relationship.
           """
         )}

      :error ->
        case lookup_attribute(cursor, leaf) do
          {:ok, %{type: type}} ->
            _ = dsl_state
            {:ok, type}

          :error ->
            {:error,
             Spark.Error.DslError.exception(
               module: original_resource,
               path: [:ash_grant, :resolve_argument, name],
               message: """
               resolve_argument :#{name} — path #{inspect(traversed ++ [leaf])} ends at
               :#{leaf} on #{inspect(cursor_module(cursor))}, but that is neither a
               relationship nor an attribute. The final path segment must be an attribute.
               """
             )}
        end
    end
  end

  defp do_validate_path(dsl_state, original_resource, [key | rest], traversed, cursor, name) do
    case lookup_relationship(cursor, key) do
      :error ->
        {:error,
         Spark.Error.DslError.exception(
           module: original_resource,
           path: [:ash_grant, :resolve_argument, name],
           message: """
           resolve_argument :#{name} — #{inspect(cursor_module(cursor))} has no
           relationship :#{key} (at path segment #{inspect(traversed ++ [key])}).
           """
         )}

      {:ok, %{type: :belongs_to, destination: destination}} ->
        do_validate_path(
          dsl_state,
          original_resource,
          rest,
          traversed ++ [key],
          {:compiled, destination},
          name
        )

      {:ok, %{type: type}} ->
        {:error,
         Spark.Error.DslError.exception(
           module: original_resource,
           path: [:ash_grant, :resolve_argument, name],
           message: """
           resolve_argument :#{name} — intermediate relationship :#{key} on
           #{inspect(cursor_module(cursor))} is a :#{type}, but only :belongs_to is
           supported for intermediate path segments.
           """
         )}
    end
  end

  # --- cursor helpers -------------------------------------------------------
  # {:dsl, dsl_state, resource} — we are inside the current resource's DSL
  # {:compiled, module}         — we are on a different, already-compiled resource

  defp cursor_module({:dsl, _dsl_state, resource}), do: resource
  defp cursor_module({:compiled, module}), do: module

  defp lookup_relationship({:dsl, dsl_state, _resource}, name) do
    dsl_state
    |> Transformer.get_entities([:relationships])
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> :error
      rel -> {:ok, rel}
    end
  end

  defp lookup_relationship({:compiled, module}, name) do
    case Ash.Resource.Info.relationship(module, name) do
      nil -> :error
      rel -> {:ok, rel}
    end
  end

  defp lookup_attribute({:dsl, dsl_state, _resource}, name) do
    dsl_state
    |> Transformer.get_entities([:attributes])
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> :error
      attr -> {:ok, attr}
    end
  end

  defp lookup_attribute({:compiled, module}, name) do
    case Ash.Resource.Info.attribute(module, name) do
      nil -> :error
      attr -> {:ok, attr}
    end
  end

  defp install_on_actions(dsl_state, decl, leaf_type, arg_map, resource) do
    scopes_needing = Map.get(arg_map, decl.name, [])

    target_actions =
      dsl_state
      |> Transformer.get_entities([:actions])
      |> Enum.filter(&target_action?(&1, decl.for_actions))

    validate_explicit_actions_exist!(decl, target_actions, resource)

    result =
      Enum.reduce(target_actions, dsl_state, fn action, state ->
        {:ok, new_state} = install_on_action(state, action, decl, leaf_type, scopes_needing)
        new_state
      end)

    {:ok, result}
  end

  defp target_action?(%{type: type, name: name}, for_actions) do
    type in @write_action_types and
      (for_actions == nil or name in for_actions)
  end

  defp target_action?(_, _), do: false

  defp validate_explicit_actions_exist!(%{for_actions: nil}, _actions, _resource), do: :ok

  defp validate_explicit_actions_exist!(
         %{for_actions: requested, name: arg_name},
         matched_actions,
         resource
       ) do
    matched_names = MapSet.new(matched_actions, & &1.name)
    missing = Enum.reject(requested, &MapSet.member?(matched_names, &1))

    if missing == [] do
      :ok
    else
      raise Spark.Error.DslError,
        module: resource,
        path: [:ash_grant, :resolve_argument, arg_name, :for_actions],
        message: """
        resolve_argument :#{arg_name} :for_actions references actions
        #{inspect(missing)} that are not defined as create/update/destroy actions on
        #{inspect(resource)}.
        """
    end
  end

  defp install_on_action(dsl_state, action, decl, leaf_type, scopes_needing) do
    new_action =
      action
      |> ensure_argument(decl.name, leaf_type)
      |> append_change(decl, scopes_needing)

    matcher = fn existing ->
      existing.__struct__ == action.__struct__ and existing.name == action.name
    end

    {:ok, Transformer.replace_entity(dsl_state, [:actions], new_action, matcher)}
  end

  defp ensure_argument(action, arg_name, leaf_type) do
    if Enum.any?(action.arguments, &(&1.name == arg_name)) do
      action
    else
      {:ok, argument} =
        Ash.Resource.Builder.build_action_argument(arg_name, leaf_type, allow_nil?: true)

      %{action | arguments: action.arguments ++ [argument]}
    end
  end

  defp append_change(action, decl, scopes_needing) do
    {:ok, change} =
      Ash.Resource.Builder.build_action_change(
        {AshGrant.Changes.ResolveArgument,
         name: decl.name, path: decl.from_path, scopes_needing: scopes_needing}
      )

    %{action | changes: action.changes ++ [change]}
  end
end

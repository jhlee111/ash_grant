defmodule AshGrant.Explainer do
  @moduledoc """
  Provides detailed explanations of authorization decisions.

  This module is the implementation behind `AshGrant.explain/4`.
  It evaluates permissions and builds an `AshGrant.Explanation` struct
  with full details about why access was allowed or denied.
  """

  alias AshGrant.{
    ArgumentAnalyzer,
    Explanation,
    Info,
    Permission,
    PermissionInput,
    Permissionable
  }

  @doc """
  Explains an authorization decision for a resource and action.

  Returns an `AshGrant.Explanation` struct with:
  - The final decision (`:allow` or `:deny`)
  - All matching permissions with their metadata
  - All evaluated permissions with match status
  - Scope information from both permissions and DSL
  - Reason for denial if applicable

  ## Examples

      iex> AshGrant.Explainer.explain(MyApp.Post, :read, actor)
      %AshGrant.Explanation{decision: :allow, ...}

      iex> AshGrant.Explainer.explain(MyApp.Post, :read, nil)
      %AshGrant.Explanation{decision: :deny, reason: :no_matching_permissions}

  """
  @spec explain(module(), atom(), term(), map()) :: Explanation.t()
  def explain(resource, action, actor, context \\ %{}) do
    resource_name = Info.resource_name(resource)
    action_str = to_string(action)
    action_type = resolve_action_type(resource, action)

    raw_permissions = get_permissions(resource, actor, context)
    permission_inputs = Enum.map(raw_permissions, &Permissionable.to_permission_input/1)

    evaluated =
      Enum.map(
        permission_inputs,
        &evaluate_permission(&1, resource, resource_name, action_str, action_type)
      )

    {decision, reason, matching_allows} = determine_decision(evaluated)
    scope_filter = resolve_explain_scope_filter(decision, matching_allows, resource, context)
    field_groups = extract_field_groups(matching_allows)
    resolve_arguments = build_resolve_arguments(resource, action)

    %Explanation{
      resource: resource,
      action: action,
      actor: actor,
      context: context,
      decision: decision,
      reason: reason,
      matching_permissions: matching_allows,
      evaluated_permissions: evaluated,
      scope_filter: scope_filter,
      field_groups: field_groups,
      field_group_defs: Info.field_groups(resource),
      resolve_arguments: resolve_arguments
    }
  end

  # Collect resolve_argument declarations active for this action, annotated with
  # the scopes that actually reference the argument. Declarations that no scope
  # uses — or that are scoped to other actions via :for_actions — are omitted.
  defp build_resolve_arguments(resource, action) do
    arg_to_scopes = ArgumentAnalyzer.arg_to_scopes(resource)

    resource
    |> Info.resolve_arguments()
    |> Enum.filter(&applies_to_action?(&1, action))
    |> Enum.map(fn decl ->
      %{
        name: decl.name,
        from_path: decl.from_path,
        for_actions: decl.for_actions,
        scopes_needing: Enum.sort(Map.get(arg_to_scopes, decl.name, []))
      }
    end)
    |> Enum.reject(&(&1.scopes_needing == []))
  end

  defp applies_to_action?(%{for_actions: nil}, _action), do: true
  defp applies_to_action?(%{for_actions: list}, action), do: action in list

  defp resolve_action_type(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: type} -> type
      _ -> nil
    end
  end

  defp evaluate_permission(input, resource, resource_name, action_str, action_type) do
    perm = Permission.from_input(input)
    matched = Permission.matches?(perm, resource_name, action_str, action_type)
    is_deny = Permission.deny?(perm)

    reason =
      explain_mismatch_reason(perm, matched, is_deny, resource_name, action_str, action_type)

    scope_name = if perm.scope, do: String.to_atom(perm.scope), else: nil

    %{
      permission: PermissionInput.to_string(input),
      matched: matched,
      is_deny: is_deny,
      reason: reason,
      description: input.description,
      source: input.source,
      scope_name: scope_name,
      scope_description: if(scope_name, do: Info.scope_description(resource, scope_name)),
      field_group: perm.field_group
    }
  end

  defp explain_mismatch_reason(_perm, true, true, _resource_name, _action_str, _action_type),
    do: "Denied by explicit deny rule"

  defp explain_mismatch_reason(_perm, true, false, _resource_name, _action_str, _action_type),
    do: nil

  defp explain_mismatch_reason(perm, false, _is_deny, resource_name, action_str, action_type) do
    cond do
      !matches_resource?(perm, resource_name) -> "Resource mismatch"
      !Permission.matches_action?(perm.action, action_str, action_type) -> "Action mismatch"
      true -> "No match"
    end
  end

  defp determine_decision(evaluated) do
    has_matching_deny = Enum.any?(evaluated, fn e -> e.matched && e.is_deny end)
    matching_allows = Enum.filter(evaluated, fn e -> e.matched && !e.is_deny end)

    cond do
      has_matching_deny -> {:deny, :denied_by_rule, matching_allows}
      matching_allows != [] -> {:allow, nil, matching_allows}
      true -> {:deny, :no_matching_permissions, matching_allows}
    end
  end

  defp resolve_explain_scope_filter(:deny, _matching_allows, _resource, _context), do: nil

  defp resolve_explain_scope_filter(:allow, [first | _], resource, context) do
    if first.scope_name do
      Info.resolve_scope_filter(resource, first.scope_name, context)
    else
      true
    end
  end

  defp resolve_explain_scope_filter(:allow, [], _resource, _context), do: nil

  defp extract_field_groups(matching_allows) do
    matching_allows
    |> Enum.map(& &1[:field_group])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Private functions

  defp get_permissions(resource, actor, context) do
    case Info.resolver(resource) do
      nil ->
        []

      resolver when is_function(resolver, 2) ->
        resolver.(actor, context) || []

      resolver when is_atom(resolver) ->
        resolver.resolve(actor, context) || []
    end
  end

  defp matches_resource?(%Permission{resource: perm_resource}, resource_name) do
    perm_resource == "*" || perm_resource == resource_name
  end
end

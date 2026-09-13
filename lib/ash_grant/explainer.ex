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

  require Ash.Expr

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

    reason_code = reason_to_code(decision, reason)
    scope_filter_string = stringify_scope_filter(scope_filter)

    summary =
      build_summary(
        decision,
        reason_code,
        matching_allows,
        evaluated,
        action,
        scope_filter_string
      )

    %Explanation{
      resource: resource,
      action: action,
      actor: actor,
      context: context,
      decision: decision,
      reason: reason,
      reason_code: reason_code,
      summary: summary,
      matching_permissions: matching_allows,
      evaluated_permissions: evaluated,
      scope_filter: scope_filter,
      scope_filter_string: scope_filter_string,
      field_groups: field_groups,
      field_group_defs: Info.field_groups(resource),
      resolve_arguments: resolve_arguments
    }
  end

  defp reason_to_code(:allow, _reason), do: :allow_matched
  defp reason_to_code(:deny, :denied_by_rule), do: :deny_rule_matched
  defp reason_to_code(:deny, :no_matching_permissions), do: :no_matching_permission
  defp reason_to_code(_, _), do: nil

  defp stringify_scope_filter(nil), do: nil
  defp stringify_scope_filter(filter), do: AshGrant.ExprStringify.to_string(filter)

  defp build_summary(:allow, :allow_matched, matching_allows, _evaluated, _action, scope_str) do
    [first | rest] = matching_allows
    extra = if rest == [], do: "", else: " (and #{length(rest)} more)"
    scope_part = allow_scope_phrase(scope_str)
    "Allowed by '#{first.permission}'#{extra}.#{scope_part}"
  end

  defp build_summary(:deny, :deny_rule_matched, _matching, evaluated, _action, _scope_str) do
    case Enum.find(evaluated, fn e -> e.matched && e.is_deny end) do
      nil -> "Denied by a deny rule."
      deny -> "Denied by '#{deny.permission}' (deny rule)."
    end
  end

  defp build_summary(:deny, :no_matching_permission, _matching, _evaluated, action, _scope_str) do
    "No matching permission for action #{inspect(action)}."
  end

  defp build_summary(_decision, _code, _matching, _evaluated, action, _scope_str) do
    "No decision information available for action #{inspect(action)}."
  end

  defp allow_scope_phrase(nil), do: ""
  defp allow_scope_phrase("true"), do: ""
  defp allow_scope_phrase(str), do: " Scope filters by #{str}."

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

  defp resolve_explain_scope_filter(:allow, [], _resource, _context), do: nil

  # Mirrors `AshGrant.FilterCheck.build_combined_filter/3`: the read path ORs
  # every matching scope, and a filter resolving to `true` absorbs the union
  # whatever the scope is named (#149). Reporting only the first matching allow
  # described a filter narrower than the one actually applied, and which of them
  # got reported depended on the order the resolver returned grants in (#151).
  defp resolve_explain_scope_filter(:allow, matching_allows, resource, context) do
    filters = Enum.map(matching_allows, &resolve_allow_filter(&1, resource, context))

    if true in filters do
      true
    else
      Enum.reduce(filters, fn filter, acc -> Ash.Expr.expr(^acc or ^filter) end)
    end
  end

  # A grant with no scope segment is unrestricted for the actions it matches.
  defp resolve_allow_filter(%{scope_name: nil}, _resource, _context), do: true

  defp resolve_allow_filter(%{scope_name: scope_name}, resource, context),
    do: Info.resolve_scope_filter(resource, scope_name, context)

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

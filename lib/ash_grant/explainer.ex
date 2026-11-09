defmodule AshGrant.Explainer do
  @moduledoc """
  Provides detailed explanations of authorization decisions.

  This module is the implementation behind `AshGrant.explain/4`.
  It evaluates permissions and builds an `AshGrant.Explanation` struct
  with full details about why access was allowed or denied.
  """

  alias AshGrant.{
    ArgumentAnalyzer,
    Evaluator,
    Explanation,
    Info,
    Introspect,
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
    grants =
      explain_permissions(
        resource,
        action,
        actor,
        context,
        get_permissions(resource, actor, context)
      )

    case get_ceiling(resource, actor, context) do
      nil ->
        grants

      ceiling ->
        within_ceiling(
          grants,
          explain_permissions(resource, action, actor, context, ceiling),
          resource
        )
    end
  end

  # The grants and the ceiling are explained as separate permission lists; the
  # action is allowed only when both allow, and their read filters are ANDed.
  defp within_ceiling(
         %Explanation{decision: :allow} = grants,
         %Explanation{decision: :allow} = ceiling,
         resource
       ) do
    scope_filter =
      AshGrant.Ceiling.intersect_filters([
        grants.scope_filter || true,
        ceiling.scope_filter || true
      ])

    scope_filter_string = stringify_scope_filter(scope_filter)

    %{
      grants
      | ceiling: ceiling,
        field_groups:
          AshGrant.Introspect.intersect_field_groups(
            resource,
            grants.field_groups,
            ceiling.field_groups
          ),
        scope_filter: scope_filter,
        scope_filter_string: scope_filter_string,
        summary:
          build_summary(
            :allow,
            :allow_matched,
            grants.matching_permissions,
            [],
            grants.action,
            scope_filter_string
          )
    }
  end

  defp within_ceiling(%Explanation{decision: :allow} = grants, ceiling, _resource) do
    %{
      grants
      | ceiling: ceiling,
        decision: :deny,
        reason: :denied_by_ceiling,
        reason_code: :ceiling_denied,
        scope_filter: nil,
        scope_filter_string: nil,
        summary: "Allowed by the actor's grants but not by the ceiling: #{ceiling.summary}"
    }
  end

  defp within_ceiling(grants, ceiling, _resource), do: %{grants | ceiling: ceiling}

  defp explain_permissions(resource, action, actor, context, raw_permissions) do
    resource_name = Info.resource_name(resource)
    action_str = to_string(action)
    action_type = resolve_action_type(resource, action)

    permission_inputs = Enum.map(raw_permissions, &Permissionable.to_permission_input/1)
    permissions = Enum.map(permission_inputs, &Permission.from_input/1)

    match = %{
      resource: resource,
      resource_name: resource_name,
      action: action_str,
      action_type: action_type,
      parents: scope_through_parents(resource, action_str, action_type),
      permissions: permissions
    }

    evaluated =
      permission_inputs
      |> Enum.zip(permissions)
      |> Enum.map(fn {input, perm} -> evaluate_permission(input, perm, match) end)

    # The verdict is the one `AshGrant.Introspect.can?/4` gives, so explain agrees
    # with the runtime on instance grants, scope_through and deny rules.
    {decision, reason} = decide(resource, action, permissions)
    matching_allows = Enum.filter(evaluated, &(&1.matched and not &1.is_deny))

    scope_filter =
      resolve_explain_scope_filter(decision, matching_allows, permissions, match, context)

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
    case Enum.find(evaluated, &(&1.matched and &1.is_deny and &1.instance_id == "*")) do
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

  defp evaluate_permission(input, perm, match) do
    is_deny = Permission.deny?(perm)
    {matched, reason} = match_permission(perm, is_deny, match)

    scope_name = if perm.scope, do: String.to_atom(perm.scope), else: nil

    %{
      permission: PermissionInput.to_string(input),
      matched: matched,
      is_deny: is_deny,
      reason: reason,
      description: input.description,
      source: input.source,
      instance_id: perm.instance_id,
      scope_name: scope_name,
      scope_description: if(scope_name, do: Info.scope_description(match.resource, scope_name)),
      field_group: perm.field_group
    }
  end

  # `matched` means the runtime counts the grant for this action: an RBAC grant
  # with a scope, a deny, the resource's own instance grant, or a parent's instance
  # grant that reaches the resource through `scope_through`.
  defp match_permission(%Permission{instance_id: "*"} = perm, is_deny, match) do
    matched = Permission.matches?(perm, match.resource_name, match.action, match.action_type)

    cond do
      not matched ->
        {false, mismatch_reason(perm, match)}

      is_deny ->
        {true, "Denied by explicit deny rule"}

      is_nil(perm.scope) ->
        {false, "No scope: an RBAC grant without a scope authorizes no records"}

      true ->
        {true, nil}
    end
  end

  defp match_permission(perm, is_deny, match) do
    action_matches? = Permission.matches_action?(perm.action, match.action, match.action_type)

    cond do
      not action_matches? ->
        {false, mismatch_reason(perm, match)}

      Permission.matches_resource?(perm.resource, match.resource_name) ->
        instance_verdict(perm, is_deny, match.resource_name, "instance", match)

      relationship = parent_relationship(perm, match.parents) ->
        instance_verdict(
          perm,
          is_deny,
          perm.resource,
          "#{perm.resource} via scope_through :#{relationship}",
          match
        )

      true ->
        {false, mismatch_reason(perm, match)}
    end
  end

  defp instance_verdict(perm, true = _is_deny, _resource_name, label, _match),
    do: {true, "Excludes #{label} #{perm.instance_id} (instance deny)"}

  defp instance_verdict(perm, false = _is_deny, resource_name, label, match) do
    if instance_denied?(match, resource_name, perm.instance_id) do
      {false, "Cancelled by an instance deny on #{perm.instance_id}"}
    else
      {true, "Grants #{label} #{perm.instance_id}"}
    end
  end

  defp instance_denied?(match, resource_name, instance_id) do
    Enum.any?(match.permissions, fn perm ->
      Permission.deny?(perm) and perm.instance_id == instance_id and
        Permission.matches_resource?(perm.resource, resource_name) and
        Permission.matches_action?(perm.action, match.action, match.action_type)
    end)
  end

  defp parent_relationship(perm, parents) do
    Enum.find_value(parents, fn {parent_name, relationship} ->
      if Permission.matches_resource?(perm.resource, parent_name), do: relationship
    end)
  end

  # `{parent resource name, relationship}` for each scope_through that applies
  # to this action.
  defp scope_through_parents(resource, action_str, action_type) do
    for scope_through <- Info.scope_throughs(resource),
        Info.scope_through_allows_action?(scope_through, action_str, action_type),
        parent = Introspect.scope_through_parent_resource(resource, scope_through) do
      {Info.resource_name(parent), scope_through.relationship}
    end
  end

  defp mismatch_reason(perm, match) do
    cond do
      !matches_resource?(perm, match.resource_name) ->
        "Resource mismatch"

      !Permission.matches_action?(perm.action, match.action, match.action_type) ->
        "Action mismatch"

      true ->
        "No match"
    end
  end

  defp decide(resource, action, permissions) do
    case Introspect.decide(resource, action, permissions) do
      {:allow, _details} -> {:allow, nil}
      {:deny, %{reason: :denied_by_rule}} -> {:deny, :denied_by_rule}
      {:deny, _details} -> {:deny, :no_matching_permissions}
    end
  end

  defp resolve_explain_scope_filter(:deny, _allows, _permissions, _match, _context), do: nil

  # The filter `AshGrant.FilterCheck` applies: the RBAC scopes ORed (a filter
  # resolving to `true` absorbs the union whatever the scope is named, #149/#151),
  # ORed with the resource's own instance ids and the scope_through parents, then
  # narrowed by the deny rules.
  defp resolve_explain_scope_filter(:allow, matching_allows, permissions, match, context) do
    %{resource: resource, action: action, action_type: action_type} = match

    rbac =
      for %{instance_id: "*"} = allow <- matching_allows,
          do: resolve_allow_filter(allow, resource, context)

    instance_ids =
      Evaluator.get_matching_instance_ids(permissions, match.resource_name, action, action_type)

    instance_filter =
      if instance_ids != [] do
        Ash.Expr.expr(^Ash.Expr.ref(Info.instance_key(resource)) in ^instance_ids)
      end

    parent_filters =
      AshGrant.FilterCheck.build_parent_instance_filters(
        resource,
        permissions,
        action,
        action_type
      )

    deny_summary = Evaluator.deny_summary(permissions, match.resource_name, action, action_type)

    if true in rbac do
      true
    else
      [or_filters(rbac), instance_filter | parent_filters]
      |> Enum.reject(&(is_nil(&1) or &1 == false))
      |> or_filters()
      |> Kernel.||(false)
    end
    |> Evaluator.restrict_filter(deny_summary, resource)
  end

  defp or_filters([]), do: nil
  defp or_filters(filters), do: Enum.reduce(filters, &Ash.Expr.expr(^&2 or ^&1))

  # A grant with no scope segment is unrestricted for the actions it matches.
  defp resolve_allow_filter(%{scope_name: nil}, _resource, _context), do: true

  defp resolve_allow_filter(%{scope_name: scope_name}, resource, context) do
    if AshGrant.Scope.universal?(to_string(scope_name)),
      do: true,
      else: Info.resolve_scope_filter(resource, scope_name, context)
  end

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

  defp get_ceiling(_resource, nil, _context), do: nil

  defp get_ceiling(resource, actor, context) do
    AshGrant.Ceiling.resolve(Info.resolver(resource), actor, context)
  end

  defp matches_resource?(%Permission{resource: perm_resource}, resource_name) do
    perm_resource == "*" || perm_resource == resource_name
  end
end

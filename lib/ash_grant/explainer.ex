defmodule AshGrant.Explainer do
  @moduledoc """
  Provides detailed explanations of authorization decisions.

  This module is the implementation behind `AshGrant.explain/4`.
  It evaluates permissions and builds an `AshGrant.Explanation` struct
  with full details about why access was allowed or denied.
  """

  alias AshGrant.{Explanation, Info, Permission, PermissionInput, Permissionable}

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

    # Get permissions from resolver
    raw_permissions = get_permissions(resource, actor, context)

    # Normalize to PermissionInput first (to preserve metadata)
    permission_inputs = Enum.map(raw_permissions, &Permissionable.to_permission_input/1)

    # Evaluate each permission
    evaluated =
      Enum.map(permission_inputs, fn input ->
        perm = Permission.from_input(input)
        matched = Permission.matches?(perm, resource_name, action_str)
        is_deny = Permission.deny?(perm)

        reason =
          cond do
            matched && is_deny -> "Denied by explicit deny rule"
            matched -> nil
            !matches_resource?(perm, resource_name) -> "Resource mismatch"
            !matches_action?(perm, action_str) -> "Action mismatch"
            true -> "No match"
          end

        # Get scope info from DSL
        scope_name = if perm.scope, do: String.to_atom(perm.scope), else: nil

        scope_description =
          if scope_name, do: Info.scope_description(resource, scope_name), else: nil

        %{
          permission: PermissionInput.to_string(input),
          matched: matched,
          is_deny: is_deny,
          reason: reason,
          description: input.description,
          source: input.source,
          scope_name: scope_name,
          scope_description: scope_description
        }
      end)

    # Check for deny-wins
    has_matching_deny =
      Enum.any?(evaluated, fn e -> e.matched && e.is_deny end)

    # Get matching allow permissions
    matching_allows =
      Enum.filter(evaluated, fn e -> e.matched && !e.is_deny end)

    # Determine decision and reason
    {decision, reason} =
      cond do
        has_matching_deny ->
          {:deny, :denied_by_rule}

        matching_allows != [] ->
          {:allow, nil}

        true ->
          {:deny, :no_matching_permissions}
      end

    # Get scope filter for reads
    scope_filter =
      if decision == :allow do
        # Get the scope from the first matching permission
        case matching_allows do
          [first | _] ->
            if first.scope_name do
              Info.resolve_scope_filter(resource, first.scope_name, context)
            else
              true
            end

          [] ->
            nil
        end
      else
        nil
      end

    %Explanation{
      resource: resource,
      action: action,
      actor: actor,
      context: context,
      decision: decision,
      reason: reason,
      matching_permissions: matching_allows,
      evaluated_permissions: evaluated,
      scope_filter: scope_filter
    }
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

  defp matches_action?(%Permission{action: perm_action}, action_str) do
    perm_action == "*" || perm_action == action_str
  end
end

defmodule AshGrant.FieldCheck do
  @moduledoc """
  SimpleCheck for field-level authorization within Ash's `field_policies`.

  This check integrates with Ash's built-in `field_policies` system to authorize
  access to specific fields based on AshGrant permission strings.

  ## Usage (Mode A — Manual)

      field_policies do
        field_policy [:salary, :ssn] do
          authorize_if AshGrant.field_check(:confidential)
        end

        field_policy [:phone, :address] do
          authorize_if AshGrant.field_check(:sensitive)
        end

        field_policy :* do
          authorize_if always()
        end
      end

  The check passes if the actor's permission string has a field_group that
  equals or inherits from the required group. If the actor's permissions
  have no field_group (4-part format), all fields are visible.
  """

  use Ash.Policy.SimpleCheck

  @doc """
  Creates a field check tuple for use in field_policies.
  """
  def field_check(field_group) when is_atom(field_group) do
    {__MODULE__, [field_group: field_group]}
  end

  @impl true
  def describe(opts) do
    field_group = Keyword.fetch!(opts, :field_group)
    "has field group access: #{field_group}"
  end

  @impl true
  def match?(actor, authorizer, opts) do
    if actor == nil do
      false
    else
      do_match?(actor, authorizer, opts)
    end
  end

  defp do_match?(actor, authorizer, opts) do
    required_group = Keyword.fetch!(opts, :field_group)
    resource_module = authorizer.resource

    resolver = AshGrant.Info.resolver(resource_module)
    resource_name = AshGrant.Info.resource_name(resource_module)
    action = authorizer.action
    action_name = to_string(action.name)
    action_type = action_type_from(action)

    context = %{
      actor: actor,
      resource: resource_module,
      action: action,
      tenant: get_tenant(authorizer)
    }

    permissions = resolve_permissions(resolver, actor, context)

    AshGrant.PermissionValidation.validate(
      permissions,
      AshGrant.Info.field_group_permissions(resource_module),
      resource: resource_module
    )

    actor_field_groups =
      AshGrant.Evaluator.get_all_field_groups(
        permissions,
        resource_name,
        action_name,
        action_type
      )

    # If no field groups specified in permissions, actor has unrestricted field access
    if actor_field_groups == [] do
      # Check if the actor has any matching permissions at all (for read access)
      AshGrant.Evaluator.has_access?(permissions, resource_name, action_name, action_type)
    else
      field_group_grants_access?(resource_module, actor_field_groups, required_group)
    end
  end

  defp action_type_from(%{type: type}), do: type
  defp action_type_from(_), do: nil

  # Check if any of the actor's field groups equals or inherits from the required group
  defp field_group_grants_access?(_resource, [], _required), do: false

  defp field_group_grants_access?(resource, actor_groups, required) do
    Enum.any?(actor_groups, fn group_name ->
      group_atom =
        if is_binary(group_name), do: String.to_existing_atom(group_name), else: group_name

      group_atom == required or inherits_from?(resource, group_atom, required)
    end)
  rescue
    ArgumentError -> false
  end

  # Recursively check if group_name inherits from target (directly or transitively)
  defp inherits_from?(resource, group_name, target) do
    case AshGrant.Info.get_field_group(resource, group_name) do
      nil ->
        false

      fg ->
        parents = fg.inherits || []
        target in parents or Enum.any?(parents, &inherits_from?(resource, &1, target))
    end
  end

  defp resolve_permissions(resolver, actor, context) when is_function(resolver, 2) do
    resolver.(actor, context)
  end

  defp resolve_permissions(resolver, actor, context) when is_atom(resolver) do
    resolver.resolve(actor, context)
  end

  defp get_tenant(authorizer) do
    case authorizer do
      %{query: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      %{changeset: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      %{action_input: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      _ -> nil
    end
  end
end

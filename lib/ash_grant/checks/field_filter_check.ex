defmodule AshGrant.FieldFilterCheck do
  @moduledoc """
  Per-record field-group visibility check (issue #117 phase ②).

  An `Ash.Policy.FilterCheck` used inside Ash `field_policies`. For a required
  field group, `filter/3` returns a per-row predicate — `false` (the group's
  fields are `%Ash.ForbiddenField{}` on every row), `true` (visible on every
  row), or an Ash expression (visible only on rows matching the contributing
  grants' scope / instance ids). Ash compiles the predicate into a per-row
  calculation, so a field can be visible on some records and forbidden on others
  in the same result set.

  This is the per-record counterpart to the action-wide `AshGrant.FieldCheck`
  (a `SimpleCheck`). It reuses `AshGrant.Evaluator.field_group_grants/5` to find
  the allow grants that reach the required group (including instance permissions
  and inheritance), then builds the predicate exactly like `AshGrant.FilterCheck`
  builds row filters.
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias AshGrant.{Evaluator, Info}

  @doc """
  Builds the check tuple for a required field group, for use in a `field_policy`.
  """
  def field_filter_check(field_group), do: {__MODULE__, [field_group: field_group]}

  @impl true
  def describe(opts) do
    "actor may see the #{inspect(opts[:field_group])} field group on this row"
  end

  @impl true
  def filter(actor, authorizer, opts) do
    if actor == nil do
      false
    else
      do_filter(actor, authorizer, opts)
    end
  end

  defp do_filter(actor, authorizer, opts) do
    required_group = Keyword.fetch!(opts, :field_group)
    resource = authorizer.resource
    action = authorizer.action
    resolver = Info.resolver(resource)
    action_name = to_string(action.name)
    action_type = action_type_from(action)

    context = %{
      actor: actor,
      resource: resource,
      action: action,
      tenant: get_tenant(authorizer)
    }

    permissions = resolve_permissions(resolver, actor, context)

    field_visibility_filter(permissions, resource, action_name, required_group, action_type)
  end

  @doc """
  Builds the per-row visibility predicate for `required_group` from `permissions`.

  Returns `false` (forbidden on every row), `true` (visible on every row), or an
  Ash expression (visible only on rows matching the contributing grants' scope /
  instance ids). Exposed for testing.
  """
  def field_visibility_filter(
        permissions,
        resource,
        action_name,
        required_group,
        action_type \\ nil
      ) do
    grants =
      Evaluator.field_group_grants(
        permissions,
        resource,
        action_name,
        required_group,
        action_type
      )

    {scopes, instance_ids} = partition_grants(grants)

    build_filter(
      scopes,
      instance_ids,
      Info.instance_key(resource),
      Info.scope_resolver(resource),
      resource
    )
  end

  # RBAC grants (instance_id "*") contribute their scope; instance grants
  # contribute their instance_id. A group-less grant keeps its scope/instance and
  # is already included by field_group_grants/5 for every group.
  defp partition_grants(grants) do
    {rbac, instance} = Enum.split_with(grants, &(&1.instance_id == "*"))

    scopes = rbac |> Enum.map(& &1.scope) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    instance_ids = instance |> Enum.map(& &1.instance_id) |> Enum.uniq()

    {scopes, instance_ids}
  end

  # Mirrors AshGrant.FilterCheck.build_filter_with_instances (raw true/false/expr)
  # but with CanPerform's empty-context scope resolution, because this predicate
  # becomes a per-row field-policy calculation that Ash fills templates on.
  defp build_filter(scopes, instance_ids, instance_key, scope_resolver, resource) do
    if global_access?(scopes) do
      true
    else
      rbac_filter = if scopes != [], do: build_rbac_filter(scopes, scope_resolver, resource)

      instance_filter =
        if instance_ids != [], do: build_instance_filter(instance_ids, instance_key)

      [rbac_filter, instance_filter]
      |> Enum.reject(&(is_nil(&1) or &1 == false))
      |> or_combine(false)
    end
  end

  defp global_access?(scopes), do: "always" in scopes or "all" in scopes or "global" in scopes

  defp build_rbac_filter(scopes, scope_resolver, resource) do
    scopes
    |> Enum.map(&resolve_scope(resource, scope_resolver, &1))
    |> Enum.reject(&(&1 == true))
    |> or_combine(true)
  end

  # OR-combine a list of Ash expressions, returning `empty` when the list is empty.
  defp or_combine([], empty), do: empty
  defp or_combine([single], _empty), do: single

  defp or_combine([first | rest], _empty),
    do: Enum.reduce(rest, first, &Ash.Expr.expr(^&2 or ^&1))

  defp build_instance_filter(instance_ids, :id) do
    Ash.Expr.expr(id in ^instance_ids)
  end

  defp build_instance_filter(instance_ids, instance_key) do
    Ash.Expr.expr(^ref(instance_key) in ^instance_ids)
  end

  # Mirrors CanPerform.resolve_scope — empty context; template refs (^actor,
  # ^tenant, ^context) are filled by Ash after the field policy compiles.
  defp resolve_scope(resource, scope_resolver, scope) do
    scope_atom = if is_binary(scope), do: String.to_existing_atom(scope), else: scope

    case Info.get_scope(resource, scope_atom) do
      nil -> resolve_with_scope_resolver(scope_resolver, scope)
      _scope_def -> Info.resolve_scope_filter(resource, scope_atom, %{})
    end
  rescue
    ArgumentError -> resolve_with_scope_resolver(scope_resolver, scope)
  end

  defp resolve_with_scope_resolver(nil, "always"), do: true
  defp resolve_with_scope_resolver(nil, "all"), do: true
  # An unknown scope with no resolver grants nothing (fail-closed at the field level).
  defp resolve_with_scope_resolver(nil, _scope), do: false

  defp resolve_with_scope_resolver(resolver, scope) when is_function(resolver, 2) do
    resolver.(scope, %{})
  end

  defp resolve_with_scope_resolver(resolver, scope) when is_atom(resolver) do
    resolver.resolve(scope, %{})
  end

  defp action_type_from(%{type: type}), do: type
  defp action_type_from(_), do: nil

  defp get_tenant(authorizer) do
    case authorizer do
      %{query: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      %{changeset: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      %{action_input: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      _ -> nil
    end
  end

  defp resolve_permissions(resolver, actor, context) when is_function(resolver, 2) do
    resolver.(actor, context)
  end

  defp resolve_permissions(resolver, actor, context) when is_atom(resolver) do
    resolver.resolve(actor, context)
  end
end

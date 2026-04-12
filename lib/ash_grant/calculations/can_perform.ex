defmodule AshGrant.Calculation.CanPerform do
  @moduledoc """
  Ash calculation that produces per-record boolean values for UI visibility.

  Mirrors `AshGrant.FilterCheck`'s logic to determine if the current actor
  can perform a specific action on each record. The result compiles to SQL
  via `expression/2`, running in a single query with no N+1.

  ## Usage

  ### DSL Sugar (Recommended)

  Use `can_perform` entities or the `can_perform_actions` batch option in your
  `ash_grant` block. The transformer auto-generates calculations at compile time:

      ash_grant do
        resolver MyApp.PermissionResolver
        scope :always, true
        scope :own, expr(author_id == ^actor(:id))

        # Batch — generates :can_update? and :can_destroy?
        can_perform_actions [:update, :destroy]

        # Individual with custom name
        can_perform :read, name: :visible?
      end

  ### Explicit Module (Advanced)

  For cases where you need full control (e.g., custom `resource_name`), you can
  still declare the calculation explicitly:

      calculations do
        calculate :can_update?, :boolean,
          {AshGrant.Calculation.CanPerform, action: "update", resource: __MODULE__},
          public?: true
      end

  DSL-generated and explicit calculations can coexist. If both declare the same
  name, the explicit one takes precedence (the transformer uses `add_new_calculation`
  which skips duplicates).

  ## Querying

      members = Member |> Ash.Query.load([:can_update?, :can_destroy?]) |> Ash.read!(actor: actor)

  In templates:

      <.button :if={member.can_update?}>Edit</.button>

  ## Options (Explicit Module)

  | Option | Type | Description |
  |--------|------|-------------|
  | `:action` | string | **Required.** Action name for permission matching (e.g., "update", "destroy") |
  | `:resource` | module | **Required.** The resource module. Use `__MODULE__` in the calculations block |
  | `:resource_name` | string | Override resource name for permission matching |

  ## How It Works

  1. Resolves actor's permissions via the configured `PermissionResolver`
  2. Gets RBAC scopes via `AshGrant.Evaluator.get_all_scopes/4`
  3. Gets instance IDs via `AshGrant.Evaluator.get_matching_instance_ids/4`
  4. Builds a combined boolean expression:
     - "always"/"all"/"global" in scopes -> `true`
     - No scopes AND no instances -> `false`
     - RBAC scopes -> scope filters combined with OR
     - Instance IDs -> `id in ^instance_ids`
     - Both -> RBAC filter OR instance filter

  ## See Also

  - `AshGrant.Transformers.AddCanPerformCalculations` - The transformer that generates calculations from DSL
  - `AshGrant.FilterCheck` - The policy check this mirrors
  - `AshGrant.Evaluator` - Permission evaluation logic
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts) do
    cond do
      !opts[:action] ->
        {:error, "action option is required for CanPerform calculation"}

      !opts[:resource] ->
        {:error,
         "resource option is required for CanPerform calculation. " <>
           "Use resource: __MODULE__ in your calculations block"}

      true ->
        {:ok, opts}
    end
  end

  @impl true
  def describe(opts) do
    "can_perform(#{opts[:action]})"
  end

  @impl true
  def expression(opts, context) do
    resource = opts[:resource]
    actor = context.actor

    if actor == nil do
      expr(false)
    else
      action = to_string(opts[:action])
      resource_name = opts[:resource_name] || AshGrant.Info.resource_name(resource)
      resolver = AshGrant.Info.resolver(resource)
      scope_resolver = AshGrant.Info.scope_resolver(resource)

      resolver_context = %{
        actor: actor,
        resource: resource,
        action: nil,
        tenant: context.tenant
      }

      instance_key = AshGrant.Info.instance_key(resource)

      permissions = resolve_permissions(resolver, actor, resolver_context)
      scopes = AshGrant.Evaluator.get_all_scopes(permissions, resource_name, action)

      instance_ids =
        AshGrant.Evaluator.get_matching_instance_ids(permissions, resource_name, action)

      parent_filters =
        build_parent_instance_filters(resource, permissions, action)

      build_expression(
        scopes,
        instance_ids,
        instance_key,
        parent_filters,
        scope_resolver,
        resource
      )
    end
  end

  # Permission resolution (mirrors FilterCheck)

  defp resolve_permissions(resolver, actor, context) when is_function(resolver, 2) do
    resolver.(actor, context)
  end

  defp resolve_permissions(resolver, actor, context) when is_atom(resolver) do
    resolver.resolve(actor, context)
  end

  # Expression building (mirrors FilterCheck's build_filter_with_instances)

  defp build_expression(
         scopes,
         instance_ids,
         instance_key,
         parent_filters,
         scope_resolver,
         resource
       ) do
    rbac_filter = build_rbac_expression(scopes, scope_resolver, resource)
    instance_filter = build_instance_expression(instance_ids, instance_key)

    # Combine all filters with OR (same logic as FilterCheck)
    all_filters =
      ([rbac_filter, instance_filter] ++ parent_filters)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == false))

    case all_filters do
      [] -> expr(false)
      [true | _] -> expr(true)
      [single] -> single
      [first | rest] -> Enum.reduce(rest, first, &expr(^&2 or ^&1))
    end
  end

  defp build_rbac_expression(scopes, scope_resolver, resource) do
    if "always" in scopes or "all" in scopes or "global" in scopes do
      true
    else
      build_rbac_filter(scopes, scope_resolver, resource)
    end
  end

  defp build_instance_expression([], _instance_key), do: nil

  defp build_instance_expression(instance_ids, instance_key),
    do: build_instance_filter(instance_ids, instance_key)

  defp build_instance_filter(instance_ids, :id) do
    expr(id in ^instance_ids)
  end

  defp build_instance_filter(instance_ids, instance_key) do
    expr(^ref(instance_key) in ^instance_ids)
  end

  # Parent instance filter building (mirrors FilterCheck's build_parent_instance_filters)

  defp build_parent_instance_filters(resource, permissions, action_name) do
    AshGrant.Info.scope_throughs(resource)
    |> Enum.flat_map(fn scope_through ->
      parent_resource = resolve_parent_resource(resource, scope_through)
      parent_resource_name = AshGrant.Info.resource_name(parent_resource)

      parent_ids =
        AshGrant.Evaluator.get_matching_instance_ids(
          permissions,
          parent_resource_name,
          action_name
        )

      if parent_ids != [] do
        relationship = Ash.Resource.Info.relationship(resource, scope_through.relationship)
        fk_field = relationship.source_attribute
        parent_dest_field = relationship.destination_attribute
        parent_instance_key = AshGrant.Info.instance_key(parent_resource)

        if parent_instance_key == parent_dest_field do
          [expr(^ref(fk_field) in ^parent_ids)]
        else
          [expr(exists(^[scope_through.relationship], ^ref(parent_instance_key) in ^parent_ids))]
        end
      else
        []
      end
    end)
  end

  defp resolve_parent_resource(resource, scope_through) do
    case scope_through.resource do
      nil ->
        relationship = Ash.Resource.Info.relationship(resource, scope_through.relationship)
        relationship.destination

      explicit ->
        explicit
    end
  end

  # RBAC filter building (mirrors FilterCheck's build_combined_filter)
  # Note: Template refs (^actor, ^tenant, ^context) in scope expressions are
  # resolved by Ash's fill_template after expression/2 returns.

  defp build_rbac_filter([], _scope_resolver, _resource), do: nil

  defp build_rbac_filter(scopes, scope_resolver, resource) do
    filters =
      scopes
      |> Enum.map(&resolve_scope(resource, scope_resolver, &1))
      |> Enum.reject(&(&1 == true))

    case filters do
      [] -> true
      [single] -> single
      multiple -> Enum.reduce(multiple, fn filter, acc -> expr(^acc or ^filter) end)
    end
  end

  # Scope resolution (mirrors FilterCheck's resolve_scope)
  # Context is not needed here because resolve_scope_filter returns raw
  # expressions with template refs that Ash fills after expression/2 returns.

  defp resolve_scope(resource, scope_resolver, scope) do
    scope_atom = if is_binary(scope), do: String.to_existing_atom(scope), else: scope

    case AshGrant.Info.get_scope(resource, scope_atom) do
      nil ->
        resolve_with_scope_resolver(scope_resolver, scope)

      _scope_def ->
        AshGrant.Info.resolve_scope_filter(resource, scope_atom, %{})
    end
  rescue
    ArgumentError ->
      resolve_with_scope_resolver(scope_resolver, scope)
  end

  defp resolve_with_scope_resolver(nil, "always"), do: true
  defp resolve_with_scope_resolver(nil, "all"), do: true

  defp resolve_with_scope_resolver(nil, scope) do
    raise """
    AshGrant.Calculation.CanPerform: Scope "#{scope}" not found in inline scope DSL \
    and no scope_resolver configured.

    Define the scope in your ash_grant block:

        ash_grant do
          resolver MyApp.PermissionResolver
          scope :#{scope}, expr(...)
        end
    """
  end

  defp resolve_with_scope_resolver(resolver, scope) when is_function(resolver, 2) do
    resolver.(scope, %{})
  end

  defp resolve_with_scope_resolver(resolver, scope) when is_atom(resolver) do
    resolver.resolve(scope, %{})
  end
end

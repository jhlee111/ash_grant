defmodule AshGrant.Check do
  @moduledoc """
  SimpleCheck for write actions (create, update, destroy).

  This check integrates with Ash's policy system to provide permission-based
  authorization for write operations. It returns `true` or `false` based on
  whether the actor has the required permission.

  For read actions, use `AshGrant.FilterCheck` instead, which returns a filter
  expression to limit query results.

  > #### Auto-generated Policies {: .info}
  >
  > When using `default_policies: true` in your resource's `ash_grant` block,
  > this check is automatically configured for write actions. You don't need
  > to manually add it to your policies.

  ## When to Use

  Use `AshGrant.check/1` for:
  - `:create` actions
  - `:update` actions
  - `:destroy` actions
  - Custom actions that modify data

  ## Usage in Policies

      policies do
        # For all write actions
        policy action_type([:create, :update, :destroy]) do
          authorize_if AshGrant.check()
        end

        # For a specific action
        policy action(:publish) do
          authorize_if AshGrant.check(action: "publish")
        end
      end

  ## Options

  | Option | Type | Description |
  |--------|------|-------------|
  | `:action` | string | Override action name for permission matching |
  | `:resource` | string | Override resource name for permission matching |

  ## How It Works

  1. **Resolve permissions**: Calls the configured `PermissionResolver` to get
     the actor's permissions
  2. **Check access**: Uses `AshGrant.Evaluator.has_access?/3` to verify
     the actor has a matching permission (deny-wins semantics)
  3. **Get scope**: Extracts the scope from the matching permission
  4. **Verify scope**: Uses `Ash.Expr.eval/2` to evaluate the scope filter
     against the target record

  ## Scope Evaluation

  Scope filters use `Ash.Expr.eval/2` for proper Ash expression handling:
  - Full support for all Ash expression operators
  - Automatic actor template resolution (`^actor(:id)`, etc.)
  - Automatic tenant template resolution (`^tenant()`)
  - Handles nested actor paths

  For **update/destroy** actions:
  - The scope filter is evaluated against the existing record (`changeset.data`)

  For **create** actions:
  - A "virtual record" is built from the changeset attributes
  - The scope filter is evaluated against this virtual record

  ## Examples

  ### Basic Usage

      # Permission: "post:*:update:own"
      # Actor can only update their own posts

      policy action(:update) do
        authorize_if AshGrant.check()
      end

  ### Action Override

      # The Ash action is :publish, but we check for "update" permission
      policy action(:publish) do
        authorize_if AshGrant.check(action: "update")
      end

  ## See Also

  - `AshGrant.FilterCheck` - For read actions
  - `AshGrant.Evaluator` - Permission evaluation logic
  - `AshGrant.Info` - DSL introspection helpers
  """

  require Ash.Expr

  @doc """
  Creates a check tuple for use in policies.

  ## Examples

      policy always() do
        authorize_if AshGrant.check()
      end

      policy action(:destroy) do
        authorize_if AshGrant.check(subject: [:status])
      end

  """
  def check(opts \\ []) do
    {__MODULE__, opts}
  end

  # Ash.Policy.Check behaviour implementation

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts) do
    action = Keyword.get(opts, :action, "current action")
    resource = Keyword.get(opts, :resource, "resource")
    "has permission for #{resource}:#{action}"
  end

  @impl true
  def match?(actor, %{resource: resource, action: action} = authorizer, opts) do
    if actor == nil do
      false
    else
      do_match?(actor, resource, action, authorizer, opts)
    end
  end

  defp do_match?(actor, resource_module, action, authorizer, opts) do
    # Get configuration from DSL
    resolver = AshGrant.Info.resolver(resource_module)
    scope_resolver = AshGrant.Info.scope_resolver(resource_module)
    configured_name = AshGrant.Info.resource_name(resource_module)

    # Note: Ash passes :resource as the module, we want a string name
    # Only use opts[:resource] if it's a string (user override)
    resource_name =
      case Keyword.get(opts, :resource) do
        nil -> configured_name
        name when is_binary(name) -> name
        _module -> configured_name
      end

    action_name = Keyword.get(opts, :action) || to_string(action.name)

    # Build context
    context = build_context(actor, resource_module, action, authorizer)

    # Resolve permissions
    permissions = resolve_permissions(resolver, actor, context)

    # Check access using evaluator
    case AshGrant.Evaluator.has_access?(permissions, resource_name, action_name) do
      false ->
        false

      true ->
        # Has permission, now check scope
        scope = AshGrant.Evaluator.get_scope(permissions, resource_name, action_name)
        check_scope_access(scope, scope_resolver, context, authorizer, opts)
    end
  end

  defp build_context(actor, resource, action, authorizer) do
    %{
      actor: actor,
      resource: resource,
      action: action,
      tenant: get_tenant(authorizer),
      changeset: get_changeset(authorizer),
      query: get_query(authorizer)
    }
  end

  defp resolve_permissions(resolver, actor, context) when is_function(resolver, 2) do
    resolver.(actor, context)
  end

  defp resolve_permissions(resolver, actor, context) when is_atom(resolver) do
    resolver.resolve(actor, context)
  end

  defp check_scope_access(nil, _scope_resolver, _context, _authorizer, _opts) do
    # No scope means no filtering (like instance permissions)
    true
  end

  defp check_scope_access("all", _scope_resolver, _context, _authorizer, _opts) do
    # "all" scope means no filtering
    true
  end

  defp check_scope_access(scope, scope_resolver, context, authorizer, opts) do
    resource = context.resource
    action_type = get_action_type(context[:action])

    case action_type do
      :create ->
        check_create_scope(scope, resource, scope_resolver, context, opts)

      _ ->
        record = get_target_record(authorizer)

        case record do
          nil -> false
          rec ->
            filter = resolve_scope(resource, scope_resolver, scope, context)
            record_matches_filter?(rec, filter, context, opts)
        end
    end
  end

  defp get_action_type(%{type: type}), do: type
  defp get_action_type(_), do: nil

  defp check_create_scope("all", _resource, _scope_resolver, _context, _opts), do: true
  defp check_create_scope("global", _resource, _scope_resolver, _context, _opts), do: true

  defp check_create_scope(scope, resource, scope_resolver, context, opts) do
    changeset = context[:changeset]

    case changeset do
      nil ->
        false

      cs ->
        virtual_record = build_virtual_record(cs)
        filter = resolve_scope(resource, scope_resolver, scope, context)
        record_matches_filter?(virtual_record, filter, context, opts)
    end
  end

  defp build_virtual_record(changeset) do
    # Extract attributes from changeset that might be used in scope filters
    # Common fields: organization_unit_id, owner_id, user_id, etc.
    attrs = changeset.attributes || %{}

    # Also include any data that was set
    data = changeset.data || %{}

    # Merge: changeset attributes take precedence
    Map.merge(Map.from_struct(data), attrs)
  rescue
    _ -> %{}
  end

  # First try inline scope DSL, then fall back to scope_resolver
  defp resolve_scope(resource, scope_resolver, scope, context) do
    scope_atom = if is_binary(scope), do: String.to_existing_atom(scope), else: scope

    # Try inline scope DSL first
    case AshGrant.Info.get_scope(resource, scope_atom) do
      nil ->
        # Fall back to legacy scope_resolver
        resolve_with_scope_resolver(scope_resolver, scope, context)

      _scope_def ->
        # Use inline scope DSL
        AshGrant.Info.resolve_scope_filter(resource, scope_atom, context)
    end
  rescue
    ArgumentError ->
      # String.to_existing_atom failed, try legacy resolver
      resolve_with_scope_resolver(scope_resolver, scope, context)
  end

  defp resolve_with_scope_resolver(nil, scope, _context) do
    raise """
    AshGrant: Scope "#{scope}" not found in inline scope DSL and no scope_resolver configured.

    Either define the scope inline in your ash_grant block:

        ash_grant do
          resolver MyApp.PermissionResolver
          scope :#{scope}, expr(...)
        end

    Or configure a scope_resolver:

        ash_grant do
          resolver MyApp.PermissionResolver
          scope_resolver MyApp.ScopeResolver
        end
    """
  end

  defp resolve_with_scope_resolver(resolver, scope, context) when is_function(resolver, 2) do
    resolver.(scope, context)
  end

  defp resolve_with_scope_resolver(resolver, scope, context) when is_atom(resolver) do
    resolver.resolve(scope, context)
  end

  defp record_matches_filter?(_record, true, _context, _opts), do: true
  defp record_matches_filter?(_record, false, _context, _opts), do: false

  defp record_matches_filter?(record, filter, context, _opts) do
    # Use Ash.Expr.eval/2 to properly evaluate expressions with actor and tenant references
    # This handles all Ash expression operators, actor template resolution, and ^tenant() resolution
    actor = context[:actor]
    tenant = context[:tenant]

    case Ash.Expr.eval(filter, record: record, actor: actor, tenant: tenant) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:ok, _other} -> true
      :unknown -> fallback_evaluation(record, filter, context)
      {:error, _} -> fallback_evaluation(record, filter, context)
    end
  end

  # Fallback for cases where Ash.Expr.eval returns :unknown or errors
  # This handles complex expressions that require data layer evaluation,
  # including tenant-based scopes like `expr(tenant_id == ^tenant())`
  #
  # The fallback checks if the expression contains tenant or actor references
  # and evaluates those specific checks.
  defp fallback_evaluation(record, filter, context) do
    tenant = context[:tenant]

    # Analyze what the filter references
    has_tenant_ref = filter_references_tenant?(filter)
    has_actor_ref = filter_references_actor?(filter)

    # Only check what the filter actually references
    tenant_ok = if has_tenant_ref, do: check_tenant_match(record, tenant), else: true
    actor_ok = if has_actor_ref, do: check_actor_match(record, filter, context), else: true

    tenant_ok and actor_ok
  end

  # Check if the filter expression references ^tenant()
  defp filter_references_tenant?(filter) do
    filter
    |> inspect()
    |> String.contains?(":_tenant")
  end

  # Check if the filter expression references ^actor()
  defp filter_references_actor?(filter) do
    filter
    |> inspect()
    |> String.contains?(":_actor")
  end

  defp check_tenant_match(_record, nil), do: false
  defp check_tenant_match(record, tenant) do
    record_tenant = Map.get(record, :tenant_id)
    if record_tenant != nil do
      to_string(record_tenant) == to_string(tenant)
    else
      # No tenant_id on record, assume it's OK
      true
    end
  end

  defp check_actor_match(record, filter, context) do
    actor = context[:actor]

    case actor do
      nil -> false
      _ ->
        # Extract the field being compared to ^actor(:id) from the filter expression
        case extract_actor_field(filter) do
          nil -> true  # No actor field found in filter, pass
          field ->
            record_owner = Map.get(record, field)
            actor_id = Map.get(actor, :id)
            record_owner == actor_id
        end
    end
  end

  # Extract the field name being compared to ^actor(:id) from a filter expression
  # This parses the filter to find patterns like `field == ^actor(:id)`
  defp extract_actor_field(filter) do
    filter_str = inspect(filter)

    # Pattern: look for `field_name == {:_actor, :id}` or similar
    # The filter string looks like: `(tenant_id == :_tenant) and (author_id == {:_actor, :id})`

    cond do
      # Match pattern: field_name == {:_actor, :id}
      match = Regex.run(~r/(\w+)\s*==\s*\{:_actor,\s*:id\}/, filter_str) ->
        [_, field_name] = match
        String.to_existing_atom(field_name)

      # Match pattern: :name, :field_name ... :_actor (for struct representations)
      match = Regex.run(~r/:name,\s*:(\w+).*:_actor/, filter_str) ->
        [_, field_name] = match
        String.to_existing_atom(field_name)

      # Match pattern: attribute: :field_name ... :_actor
      match = Regex.run(~r/attribute:\s*:(\w+).*:_actor/, filter_str) ->
        [_, field_name] = match
        String.to_existing_atom(field_name)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  # Helper functions to extract data from authorizer

  defp get_tenant(authorizer) do
    case authorizer do
      %{query: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      %{changeset: %{tenant: tenant}} when not is_nil(tenant) -> tenant
      _ -> nil
    end
  end

  defp get_changeset(%{changeset: changeset}), do: changeset
  defp get_changeset(_), do: nil

  defp get_query(%{query: query}), do: query
  defp get_query(_), do: nil

  defp get_target_record(authorizer) do
    case authorizer do
      %{changeset: %{data: data}} when not is_nil(data) -> data
      %{query: %{data: [record | _]}} -> record
      _ -> nil
    end
  end
end

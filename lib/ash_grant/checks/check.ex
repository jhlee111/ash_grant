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
    owner_field = AshGrant.Info.owner_field(resource_module)

    # Build context
    context = build_context(actor, resource_module, action, authorizer, owner_field)

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

  defp build_context(actor, resource, action, authorizer, owner_field) do
    %{
      actor: actor,
      resource: resource,
      action: action,
      owner_field: owner_field,
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
    # Use Ash.Expr.eval/2 to properly evaluate expressions with actor references
    # This handles all Ash expression operators and actor template resolution
    actor = context[:actor]

    case Ash.Expr.eval(filter, record: record, actor: actor) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:ok, _other} -> true
      :unknown -> fallback_evaluation(record, context)
      {:error, _} -> fallback_evaluation(record, context)
    end
  end

  # Fallback for cases where Ash.Expr.eval returns :unknown
  # This can happen with complex expressions that require data layer evaluation
  defp fallback_evaluation(record, context) do
    owner_field = context[:owner_field]
    actor = context[:actor]

    if owner_field && actor do
      record_owner = Map.get(record, owner_field)
      actor_id = Map.get(actor, :id)
      record_owner == actor_id
    else
      # Cannot evaluate - default to allowing (Ash will handle filtering)
      true
    end
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

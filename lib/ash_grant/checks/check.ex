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
  - Context injection via `^context(:key)` for testable scopes
  - Handles nested actor paths

  For **update/destroy** actions:
  - The scope filter is evaluated against the existing record (`changeset.data`)

  For **create** actions:
  - A "virtual record" is built from the changeset attributes
  - The scope filter is evaluated against this virtual record

  ## Relational Scopes (`exists()`) Limitation

  Scopes using `exists()` (e.g., `expr(exists(team.memberships, user_id == ^actor(:id)))`)
  cannot be fully evaluated in-memory for write actions. The `exists()` condition
  requires database queries (SQL EXISTS subquery) which are not available during
  in-memory evaluation.

  **Behavior:**
  - `exists()` nodes are replaced with `true` before in-memory evaluation
  - Attribute-based conditions in the same scope are still enforced
  - A compile-time warning is emitted when `exists()` scopes are detected
    with write policies (see `AshGrant.Transformers.ValidateScopes`)

  **Example:** For a mixed scope like
  `expr(author_id == ^actor(:id) and exists(team.memberships, user_id == ^actor(:id)))`:
  - The `author_id == ^actor(:id)` check is preserved and enforced
  - The `exists(...)` condition is treated as `true` (not enforced)

  For read actions, `exists()` works correctly via `AshGrant.FilterCheck`,
  which converts it to a SQL EXISTS subquery in the database query.

  If you need relational authorization for write actions, consider:
  - Using a custom `Ash.Policy.Check` that queries the database
  - Moving the relational check to a change or validation on the action

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

  @doc """
  Simplifies a check reference into a SAT expression of simpler check references.

  For AshGrant checks, we return the ref unchanged since permissions are resolved
  dynamically at runtime and cannot be further decomposed statically.

  This callback is used by Ash's SAT solver to optimize policy evaluation.
  """
  @impl true
  def simplify(ref, _context) do
    ref
  end

  @doc """
  Determines if one check reference implies another.

  Two AshGrant checks imply each other if they have identical options (same action
  and resource overrides). This helps the SAT solver avoid redundant evaluations.

  ## Examples

      # Same check implies itself
      implies?({Check, []}, {Check, []}, context) == true

      # Different actions don't imply each other
      implies?({Check, [action: "read"]}, {Check, [action: "update"]}, context) == false

  """
  @impl true
  def implies?(ref1, ref2, _context) do
    normalize_ref(ref1) == normalize_ref(ref2)
  end

  @doc """
  Determines if two check references conflict (are mutually exclusive).

  AshGrant checks don't inherently conflict with each other. The deny-wins
  semantics are handled at permission evaluation time, not at the check level.

  Returns `false` for all cases.
  """
  @impl true
  def conflicts?(_ref1, _ref2, _context) do
    false
  end

  # Normalize ref to handle both {Module, opts} and Module formats
  defp normalize_ref({module, opts}) when is_atom(module) and is_list(opts) do
    {module, Enum.sort(opts)}
  end

  defp normalize_ref(module) when is_atom(module) do
    {module, []}
  end

  defp normalize_ref(other), do: other

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
          nil ->
            false

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

    # Replace exists() nodes with true before in-memory evaluation.
    # Ash.Expr.eval cannot resolve exists() in-memory (requires DB queries).
    # - For create: exists() is meaningless (record doesn't exist yet)
    # - For update/destroy: exists() requires data layer queries that can't run in-memory
    # Attribute-based checks (e.g., author_id == ^actor(:id)) are preserved.
    simplified = simplify_exists_for_eval(filter)

    case Ash.Expr.eval(simplified, record: record, actor: actor, tenant: tenant) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:ok, _other} -> true
      :unknown -> fallback_evaluation(record, filter, context)
      {:error, _} -> fallback_evaluation(record, filter, context)
    end
  end

  # Replace exists() nodes with true for in-memory evaluation.
  # Ash.Expr.eval cannot resolve exists() without DB queries, causing a crash:
  # `nil.persisted(:relationships_by_name)` (ArgumentError)
  defp simplify_exists_for_eval(true), do: true
  defp simplify_exists_for_eval(false), do: false

  defp simplify_exists_for_eval(filter) do
    Ash.Filter.map(filter, fn
      %Ash.Query.Exists{} -> true
      other -> other
    end)
  end

  # Fallback for cases where Ash.Expr.eval returns :unknown or errors
  # This handles complex expressions that require data layer evaluation,
  # including tenant-based scopes like `expr(tenant_id == ^tenant())`
  #
  # The fallback checks if the expression contains tenant or actor references
  # and evaluates those specific checks.
  defp fallback_evaluation(record, filter, context) do
    tenant = context[:tenant]

    # First try to extract "field in [list]" pattern (from scope_resolver)
    case extract_in_list_check(filter) do
      {field, list} when is_list(list) ->
        record_value = Map.get(record, field)
        record_value in list

      _ ->
        # Analyze what the filter references
        has_tenant_ref = filter_references_tenant?(filter)
        has_actor_ref = filter_references_actor?(filter)

        # Only check what the filter actually references
        tenant_ok = if has_tenant_ref, do: check_tenant_match(record, tenant), else: true
        actor_ok = if has_actor_ref, do: check_actor_match(record, filter, context), else: true

        tenant_ok and actor_ok
    end
  end

  # Extract "field in [list]" pattern from filter expression (used by scope_resolver)
  # Returns {field, list} tuple or nil
  defp extract_in_list_check(filter) do
    # Parse from string/inspect representation
    filter_str = inspect(filter)

    cond do
      # Simple format: "field_name in [\"id1\", \"id2\"]"
      match = Regex.run(~r/^(\w+)\s+in\s+\[(.+)\]$/, filter_str) ->
        [_, field_name, list_content] = match
        ids = Regex.scan(~r/"([^"]+)"/, list_content) |> Enum.map(fn [_, id] -> id end)
        if ids != [], do: {String.to_existing_atom(field_name), ids}, else: nil

      # Complex Ash.Query format with :in
      String.contains?(filter_str, ":in") and String.contains?(filter_str, "[\"") ->
        extract_in_list_from_inspect(filter_str)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_in_list_from_inspect(filter_str) do
    # Extract field name: look for :name, :field_name pattern
    field_match = Regex.run(~r/attribute:\s*%[^}]*:name,\s*:(\w+)/, filter_str)

    # Extract list: look for ["id1", "id2", ...] pattern
    list_match = Regex.run(~r/\["([^"]+)"(?:,\s*"([^"]+)")*\]/, filter_str)

    case {field_match, list_match} do
      {[_, field_name], [full_match | _]} ->
        # Parse all IDs from the list
        ids = Regex.scan(~r/"([^"]+)"/, full_match) |> Enum.map(fn [_, id] -> id end)
        if ids != [], do: {String.to_existing_atom(field_name), ids}, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
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
      nil ->
        false

      _ ->
        # First try to extract "field in ^actor(:list_field)" pattern
        case extract_actor_in_list_check(filter) do
          {record_field, actor_field} ->
            # Check if record's field value is in actor's list field
            record_value = Map.get(record, record_field)
            actor_list = Map.get(actor, actor_field) || []
            record_value in actor_list

          nil ->
            # Fall back to extract "field == ^actor(:actor_field)" pattern
            case extract_actor_equality_check(filter) do
              {record_field, actor_field} ->
                record_value = Map.get(record, record_field)
                actor_value = Map.get(actor, actor_field)
                record_value == actor_value

              nil ->
                # No actor pattern found, assume OK (other checks may apply)
                true
            end
        end
    end
  end

  # Extract "field in ^actor(:list_field)" pattern from filter expression
  # Returns {record_field, actor_field} tuple or nil
  defp extract_actor_in_list_check(filter) do
    filter_str = inspect(filter)

    # Pattern: look for `field_name in {:_actor, :list_field}`
    # The filter string looks like: `organization_unit_id in {:_actor, :accessible_org_unit_ids}`
    cond do
      match = Regex.run(~r/(\w+)\s+in\s+\{:_actor,\s*:(\w+)\}/, filter_str) ->
        [_, record_field, actor_field] = match
        {String.to_existing_atom(record_field), String.to_existing_atom(actor_field)}

      # Also match Ash.Expr struct representations
      match = Regex.run(~r/:name,\s*:(\w+).*:in.*:_actor.*:(\w+)/, filter_str) ->
        [_, record_field, actor_field] = match
        {String.to_existing_atom(record_field), String.to_existing_atom(actor_field)}

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  # Extract "field == ^actor(:actor_field)" pattern from filter expression
  # Returns {record_field, actor_field} tuple or nil
  # This handles any actor field (not just :id), e.g., `field == ^actor(:org_unit_id)`
  defp extract_actor_equality_check(filter) do
    filter_str = inspect(filter)

    # Pattern: look for `field_name == {:_actor, :actor_field}` or similar
    # The filter string looks like: `organization_unit_id == {:_actor, :org_unit_id}`

    cond do
      # Match pattern: field_name == {:_actor, :actor_field}
      match = Regex.run(~r/(\w+)\s*==\s*\{:_actor,\s*:(\w+)\}/, filter_str) ->
        [_, record_field, actor_field] = match
        {String.to_existing_atom(record_field), String.to_existing_atom(actor_field)}

      # Match Ash.Expr struct representations with equality
      # e.g., `%Ash.Query.Operator.Eq{... left: %{name: :organization_unit_id}, right: {:_actor, :org_unit_id}}`
      match = Regex.run(~r/:name,\s*:(\w+).*:_actor,\s*:(\w+)/, filter_str) ->
        [_, record_field, actor_field] = match
        {String.to_existing_atom(record_field), String.to_existing_atom(actor_field)}

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

defmodule AshGrant.Check do
  @moduledoc """
  SimpleCheck for write and generic actions.

  This check integrates with Ash's policy system to provide permission-based
  authorization for write operations and generic actions. It returns `true` or
  `false` based on whether the actor has the required permission.

  For read actions, use `AshGrant.FilterCheck` instead, which returns a filter
  expression to limit query results.

  > #### Auto-generated Policies {: .info}
  >
  > When using `default_policies: true` in your resource's `ash_grant` block,
  > this check is automatically configured for write actions and generic actions.

  ## When to Use

  Use `AshGrant.check/1` for:
  - `:create` actions
  - `:update` actions
  - `:destroy` actions
  - `:action` (generic actions)

  ## Usage in Policies

      policies do
        # For all write actions
        policy action_type([:create, :update, :destroy]) do
          authorize_if AshGrant.check()
        end

        # For generic actions (not included in default_policies)
        policy action_type(:action) do
          authorize_if AshGrant.check()
        end

        # For a specific action
        policy action(:publish) do
          authorize_if AshGrant.check(action: "publish")
        end
      end

  ## Generic Actions

  Generic actions (Ash actions with `type: :action`) use `Ash.ActionInput`
  instead of `Ash.Query` or `Ash.Changeset`. This check correctly extracts
  tenant from `action_input` for multi-tenant authorization.

  Generic actions must be authorized by their specific action name in the
  permission string — type wildcards (`action*`) do not apply because generic
  actions are individually unique:

      # Permission grants access to the specific "ping" action
      "service_request:*:ping:always"

      # Wildcard (*) grants access to all actions including generic ones
      "service_request:*:*:always"

  Since generic actions have no target record, only `scope :always, true` (or
  other non-record scopes) will pass scope evaluation. Record-based scopes
  like `scope :own, expr(author_id == ^actor(:id))` are not applicable.

  > #### default_policies and generic actions {: .info}
  >
  > `default_policies: true` automatically generates a policy for generic actions
  > using `AshGrant.Check`.

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

  ## Dual Read/Write Scope

  This check uses `AshGrant.Info.resolve_write_scope_filter/3` for scope resolution,
  which checks the scope's `write:` option first, falling back to `filter` if not set.
  This allows scopes to provide separate expressions for reads and writes.

  The `write:` option is an explicit override. When omitted, the check automatically
  chooses the best strategy for the scope expression (see "DB Query Fallback" below).

      # Explicit in-memory override (avoids DB round-trip)
      scope :same_org, expr(exists(org.users, id == ^actor(:id))),
        write: expr(org_id == ^actor(:org_id))

  Set `write: false` to explicitly deny writes with a scope:

      scope :readonly, expr(exists(org.users, id == ^actor(:id))),
        write: false

  ## Relational Scopes and DB Query Fallback

  Scopes using `exists()` or dot-path references cannot be evaluated in-memory.
  When such a scope has no explicit `write:` option and the resource has a data layer,
  the check automatically uses a **DB query** to verify the scope instead:

  | `write:` value | Strategy | Behavior |
  |---|---|---|
  | `write: false` | Deny | Returns false immediately |
  | `write: true` | Allow | Returns true immediately |
  | `write: expr(...)` | In-memory | Evaluate custom expression |
  | _(omitted, no relationships)_ | In-memory | Current behavior |
  | _(omitted, has relationships)_ | **DB query** | Query DB with read scope |

  **For update/destroy**: Queries the DB to check if the existing record matches
  the read scope expression.

  **For create**: Splits the filter into direct-attribute parts (evaluated in-memory)
  and relationship parts. Relationship parts are verified by extracting the FK from
  the changeset and querying the parent resource.

  This means scopes like `exists(team.memberships, user_id == ^actor(:id))` now work
  correctly for all action types without requiring a `write:` option.

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
  require Ash.Query

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

    # When action is overridden via opts, don't infer action_type
    {action_name, action_type} =
      case Keyword.get(opts, :action) do
        nil -> {to_string(action.name), action_type_from(action)}
        override -> {override, nil}
      end

    # Build context
    context = build_context(actor, resource_module, action, authorizer)

    # Resolve permissions
    permissions = resolve_permissions(resolver, actor, context)

    # Check access using evaluator
    case AshGrant.Evaluator.has_access?(permissions, resource_name, action_name, action_type) do
      false ->
        # RBAC check failed — try scope_through (parent instance permissions)
        check_scope_through_write(
          resource_module,
          permissions,
          action_name,
          action_type,
          authorizer
        )

      true ->
        # Has permission, now check scope
        scope =
          AshGrant.Evaluator.get_scope(permissions, resource_name, action_name, action_type)

        check_scope_access(scope, scope_resolver, context, authorizer, opts)
    end
  end

  defp check_scope_through_write(
         resource_module,
         permissions,
         action_name,
         action_type,
         authorizer
       ) do
    scope_throughs = AshGrant.Info.scope_throughs(resource_module)

    if scope_throughs == [] do
      false
    else
      # Get the record being written (from changeset data or authorizer)
      record = get_target_record(authorizer)

      Enum.any?(scope_throughs, fn scope_through ->
        # Check action filter
        action_allowed =
          scope_through.actions == nil or
            action_type_atom(action_name, action_type) in scope_through.actions

        if action_allowed do
          parent_resource = resolve_parent_resource(resource_module, scope_through)
          parent_resource_name = AshGrant.Info.resource_name(parent_resource)

          parent_ids =
            AshGrant.Evaluator.get_matching_instance_ids(
              permissions,
              parent_resource_name,
              action_name,
              action_type
            )

          if parent_ids != [] and record do
            relationship =
              Ash.Resource.Info.relationship(resource_module, scope_through.relationship)

            fk_field = relationship.source_attribute
            fk_value = to_string(Map.get(record, fk_field))
            fk_value in parent_ids
          else
            false
          end
        else
          false
        end
      end)
    end
  end

  defp resolve_parent_resource(resource_module, scope_through) do
    case scope_through.resource do
      nil ->
        relationship = Ash.Resource.Info.relationship(resource_module, scope_through.relationship)
        relationship.destination

      explicit ->
        explicit
    end
  end

  defp action_type_atom(_action_name, action_type)
       when is_atom(action_type) and not is_nil(action_type),
       do: action_type

  defp action_type_atom(action_name, _) when is_binary(action_name),
    do: String.to_existing_atom(action_name)

  defp action_type_atom(action_name, _) when is_atom(action_name), do: action_name

  defp action_type_from(%{type: type}), do: type
  defp action_type_from(_), do: nil

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

  defp check_scope_access("always", _scope_resolver, _context, _authorizer, _opts) do
    true
  end

  defp check_scope_access("all", _scope_resolver, _context, _authorizer, _opts) do
    true
  end

  defp check_scope_access(scope, scope_resolver, context, authorizer, opts) do
    resource = context.resource
    action_type = get_action_type(context[:action])

    # Resolve the write scope filter (uses write: if set, else filter)
    scope_filter = resolve_scope(resource, scope_resolver, scope, context)

    case scope_filter do
      true ->
        true

      false ->
        false

      filter ->
        check_scope_with_strategy(scope, filter, resource, action_type, context, authorizer, opts)
    end
  end

  # Decide between DB query and in-memory evaluation, then execute.
  defp check_scope_with_strategy(scope, filter, resource, action_type, context, authorizer, opts) do
    scope_def = get_scope_def(resource, scope)

    if should_use_db_query?(scope_def, filter, resource) do
      read_filter = resolve_read_scope(resource, scope, context)
      db_query_scope_check(resource, action_type, authorizer, read_filter, context)
    else
      check_scope_in_memory(action_type, filter, context, authorizer, opts)
    end
  end

  defp check_scope_in_memory(:create, filter, context, _authorizer, opts) do
    check_create_scope_in_memory(context, filter, opts)
  end

  defp check_scope_in_memory(_action_type, filter, context, authorizer, opts) do
    record = get_target_record(authorizer)
    if record, do: record_matches_filter?(record, filter, context, opts), else: false
  end

  defp get_action_type(%{type: type}), do: type
  defp get_action_type(_), do: nil

  # In-memory evaluation for create actions (no DB query needed)
  defp check_create_scope_in_memory(context, filter, opts) do
    changeset = context[:changeset]

    case changeset do
      nil ->
        false

      cs ->
        virtual_record = build_virtual_record(cs)
        record_matches_filter?(virtual_record, filter, context, opts)
    end
  end

  # ============================================================
  # DB Query Strategy
  # ============================================================

  # Determine if we should use a DB query instead of in-memory evaluation.
  # Used when: scope has relationship references, no explicit write: option, and resource has a data layer.
  defp should_use_db_query?(nil, _filter, _resource), do: false

  defp should_use_db_query?(scope_def, filter, resource) do
    is_nil(scope_def.write) and
      has_data_layer?(resource) and
      contains_relationship_reference?(filter)
  end

  defp has_data_layer?(resource) do
    Ash.DataLayer.data_layer(resource) != nil
  rescue
    _ -> false
  end

  # Check if an Ash expression contains relationship references (exists() or dot-paths).
  # The filter at this stage is a mix of hydrated (%Ref{}, %Exists{}) and unhydrated
  # (%Ash.Query.Call{}) nodes, so we walk the AST manually rather than using
  # Ash.Filter.relationship_paths/4 (which assumes a fully hydrated filter).
  defp contains_relationship_reference?(true), do: false
  defp contains_relationship_reference?(false), do: false
  defp contains_relationship_reference?(nil), do: false
  defp contains_relationship_reference?(%Ash.Query.Exists{}), do: true

  defp contains_relationship_reference?(%Ash.Query.Ref{relationship_path: p}) when p != [],
    do: true

  defp contains_relationship_reference?(%Ash.Query.BooleanExpression{left: l, right: r}) do
    contains_relationship_reference?(l) or contains_relationship_reference?(r)
  end

  defp contains_relationship_reference?(%Ash.Query.Not{expression: e}),
    do: contains_relationship_reference?(e)

  defp contains_relationship_reference?(%Ash.Query.Call{args: args}) do
    Enum.any?(args, &contains_relationship_reference?/1)
  end

  # Hydrated Ash function structs (if/is_nil/contains/fragment/etc.) carry args in :arguments
  defp contains_relationship_reference?(%{__function__?: true, arguments: arguments}) do
    Enum.any?(arguments, &contains_relationship_reference?/1)
  end

  # Operators and other binary-shape structs
  defp contains_relationship_reference?(%{__struct__: _, left: l, right: r}) do
    contains_relationship_reference?(l) or contains_relationship_reference?(r)
  end

  # Lists appear as RHS of `in` operator and function arguments
  defp contains_relationship_reference?(list) when is_list(list) do
    Enum.any?(list, &contains_relationship_reference?/1)
  end

  defp contains_relationship_reference?(_), do: false

  # Get a scope definition from the DSL
  defp get_scope_def(resource, scope) do
    scope_atom = if is_binary(scope), do: String.to_existing_atom(scope), else: scope
    AshGrant.Info.get_scope(resource, scope_atom)
  rescue
    ArgumentError -> nil
  end

  # Resolve the READ scope filter (ignoring write: option)
  defp resolve_read_scope(resource, scope, context) do
    scope_atom = if is_binary(scope), do: String.to_existing_atom(scope), else: scope
    AshGrant.Info.resolve_scope_filter(resource, scope_atom, context)
  rescue
    ArgumentError -> false
  end

  # Route to the correct DB query strategy based on action type
  defp db_query_scope_check(resource, :create, _authorizer, read_filter, context) do
    changeset = context[:changeset]

    if changeset,
      do: db_query_create_check(resource, changeset, read_filter, context),
      else: false
  end

  defp db_query_scope_check(resource, _action_type, authorizer, read_filter, context) do
    record = get_target_record(authorizer)

    if record,
      do: db_query_record_check(resource, record, read_filter, context),
      else: false
  end

  # DB query for update/destroy: "does this record match the read scope?"
  defp db_query_record_check(resource, record, scope_filter, context) do
    pk_fields = Ash.Resource.Info.primary_key(resource)
    pk_filter = Enum.map(pk_fields, fn field -> {field, Map.get(record, field)} end)

    # Resolve actor/tenant templates before passing to query
    resolved_filter = resolve_templates(scope_filter, context)

    resource
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(^resolved_filter)
    |> Ash.Query.filter(^pk_filter)
    |> Ash.exists?(exists_opts(context))
  rescue
    _ -> false
  end

  # DB query for create: record doesn't exist yet, so we split the filter
  # into direct-attribute parts (eval in-memory) and relationship parts (query DB).
  defp db_query_create_check(resource, changeset, scope_filter, context) do
    {direct_filter, relationship_parts} = split_filter_for_create(scope_filter)

    # Check direct-attribute conditions in-memory
    direct_ok =
      case direct_filter do
        true ->
          true

        false ->
          false

        filter ->
          virtual_record = build_virtual_record(changeset)
          record_matches_filter?(virtual_record, filter, context, [])
      end

    # Check relationship conditions via DB
    relationship_ok =
      Enum.all?(relationship_parts, fn part ->
        check_relationship_via_db(resource, changeset, part, context)
      end)

    direct_ok and relationship_ok
  end

  # Split a filter expression into direct-attribute parts and relationship parts.
  defp split_filter_for_create(%Ash.Query.Exists{} = exists) do
    {true, [exists]}
  end

  defp split_filter_for_create(%Ash.Query.BooleanExpression{op: :and, left: left, right: right}) do
    {left_direct, left_rels} = split_filter_for_create(left)
    {right_direct, right_rels} = split_filter_for_create(right)
    direct = combine_and(left_direct, right_direct)
    {direct, left_rels ++ right_rels}
  end

  defp split_filter_for_create(other) do
    if contains_relationship_reference?(other) do
      {true, [other]}
    else
      {other, []}
    end
  end

  defp combine_and(true, right), do: right
  defp combine_and(left, true), do: left
  defp combine_and(false, _), do: false
  defp combine_and(_, false), do: false
  defp combine_and(left, right), do: Ash.Expr.expr(^left and ^right)

  # Handle exists() by extracting FK from changeset and querying the parent resource.
  defp check_relationship_via_db(
         resource,
         changeset,
         %Ash.Query.Exists{path: [rel | rest], expr: inner},
         context
       ) do
    target_filter =
      if rest == [], do: inner, else: %Ash.Query.Exists{path: rest, expr: inner, at_path: []}

    query_relationship_from_changeset(resource, changeset, rel, target_filter, context)
  rescue
    _ -> false
  end

  # Handle expressions containing dot-path refs (e.g., order.center_id in ^actor(:ids))
  defp check_relationship_via_db(resource, changeset, expr, context) do
    case extract_first_relationship(expr) do
      nil ->
        false

      rel_name ->
        transformed = transform_refs_for_target(expr, rel_name)
        query_relationship_from_changeset(resource, changeset, rel_name, transformed, context)
    end
  rescue
    _ -> false
  end

  # Query a parent resource via FK from changeset to check if the filter matches.
  defp query_relationship_from_changeset(resource, changeset, rel_name, target_filter, context) do
    with relationship when not is_nil(relationship) <-
           Ash.Resource.Info.relationship(resource, rel_name),
         fk_value when not is_nil(fk_value) <- get_fk_from_changeset(changeset, relationship) do
      resolved = resolve_templates(target_filter, context)

      relationship.destination
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(^[{relationship.destination_attribute, fk_value}])
      |> Ash.Query.filter(^resolved)
      |> Ash.exists?(exists_opts(context))
    else
      _ -> false
    end
  end

  # Build opts for Ash.exists? — always skip authorization, pass tenant if present
  defp exists_opts(context) do
    opts = [authorize?: false]
    if context[:tenant], do: Keyword.put(opts, :tenant, context[:tenant]), else: opts
  end

  # Resolve actor/tenant/context/arguments templates in an expression
  defp resolve_templates(filter, context) do
    Ash.Expr.fill_template(filter,
      actor: context[:actor],
      tenant: context[:tenant],
      context: context[:query_context] || %{},
      args: extract_arguments(context)
    )
  end

  defp extract_arguments(context) do
    case context[:changeset] do
      %{arguments: args} when is_map(args) -> args
      _ -> %{}
    end
  end

  # For belongs_to: source_attribute is the FK (e.g., :team_id)
  defp get_fk_from_changeset(changeset, relationship) do
    Ash.Changeset.get_attribute(changeset, relationship.source_attribute)
  end

  # Extract first relationship name from an expression containing dot-path refs
  defp extract_first_relationship(%Ash.Query.Ref{relationship_path: [rel | _]}), do: rel

  defp extract_first_relationship(%Ash.Query.BooleanExpression{left: l, right: r}) do
    extract_first_relationship(l) || extract_first_relationship(r)
  end

  defp extract_first_relationship(%Ash.Query.Call{args: args}) do
    Enum.find_value(args, &extract_first_relationship/1)
  end

  defp extract_first_relationship(%{__struct__: _, left: l, right: r}) do
    extract_first_relationship(l) || extract_first_relationship(r)
  end

  defp extract_first_relationship(_), do: nil

  # Transform dot-path refs: remove the first relationship from relationship_path
  defp transform_refs_for_target(expr, rel_name) do
    Ash.Filter.map(expr, fn
      %Ash.Query.Ref{relationship_path: [^rel_name | rest]} = ref ->
        %{ref | relationship_path: rest}

      other ->
        other
    end)
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

  # First try inline scope DSL (using write scope resolution), then fall back to scope_resolver.
  # Write scope resolution uses the scope's `write:` option if set, otherwise falls back to `filter`.
  defp resolve_scope(resource, scope_resolver, scope, context) do
    scope_atom = if is_binary(scope), do: String.to_existing_atom(scope), else: scope

    # Try inline scope DSL first
    case AshGrant.Info.get_scope(resource, scope_atom) do
      nil ->
        # Fall back to legacy scope_resolver
        resolve_with_scope_resolver(scope_resolver, scope, context)

      _scope_def ->
        # Use write scope resolution for write actions (in-memory evaluation)
        AshGrant.Info.resolve_write_scope_filter(resource, scope_atom, context)
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
    actor = context[:actor]
    tenant = context[:tenant]
    resource = context[:resource]

    # Replace exists() nodes with true before in-memory evaluation.
    # Ash.Expr.eval cannot resolve exists() in-memory (requires DB queries).
    simplified = simplify_exists_for_eval(filter)

    # Resolve actor/tenant/context/arguments templates to concrete values before
    # eval, then pass resource: so Ash can hydrate attribute references.
    filled =
      Ash.Expr.fill_template(simplified,
        actor: actor,
        tenant: tenant,
        context: %{},
        args: extract_arguments(context)
      )

    case Ash.Expr.eval(filled, record: record, resource: resource, actor: actor, tenant: tenant) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:ok, nil} -> false
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

  defp check_actor_match(_record, _filter, %{actor: nil}), do: false

  defp check_actor_match(record, filter, context) do
    actor = context[:actor]

    case extract_actor_in_list_check(filter) do
      {record_field, actor_field} ->
        evaluate_actor_in_list(record, actor, record_field, actor_field)

      nil ->
        evaluate_actor_equality_or_default(record, filter, actor)
    end
  end

  defp evaluate_actor_in_list(record, actor, record_field, actor_field) do
    record_value = Map.get(record, record_field)
    actor_list = Map.get(actor, actor_field) || []
    record_value in actor_list
  end

  defp evaluate_actor_equality_or_default(record, filter, actor) do
    case extract_actor_equality_check(filter) do
      {record_field, actor_field} ->
        Map.get(record, record_field) == Map.get(actor, actor_field)

      nil ->
        true
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
      %{action_input: %{tenant: tenant}} when not is_nil(tenant) -> tenant
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

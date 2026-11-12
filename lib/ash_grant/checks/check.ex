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

  Generic actions are best authorized by their specific action name in the
  permission string, because generic actions are individually unique:

      # Permission grants access to the specific "ping" action
      "service_request:*:ping:always"

      # Wildcard (*) grants access to all actions including generic ones
      "service_request:*:*:always"

      # The @action type wildcard grants EVERY generic action on the resource,
      # including ones added later — the grant that permits :ping also permits
      # :process_refund. Prefer exact action names.
      "service_request:*:@action:always"

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
  2. **Collect scopes**: Uses `AshGrant.Evaluator.get_write_scopes/4` to gather
     the scopes of ALL matching allow grants (deny-wins semantics)
  3. **Verify scopes**: Evaluates each scope filter with `Ash.Expr.eval/2`
     against the target record — the action is authorized if ANY grant's
     scope passes. Grants are additive: a narrow grant never shadows a
     broader one (issue #123), matching the read path's OR-composition

  ## Scope Evaluation

  Scope filters use `Ash.Expr.eval/2` for proper Ash expression handling:
  - Full support for all Ash expression operators
  - Automatic actor template resolution (`^actor(:id)`, etc.)
  - Automatic tenant template resolution (`^tenant()`)
  - Context injection via `^context(:key)` for testable scopes
  - Handles nested actor paths

  If `Ash.Expr.eval/2` cannot evaluate the scope against the record (it returns
  `:unknown` or an error, such as a failed `type/2` cast or an unknown field),
  the check denies the write and logs a warning.

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

  > #### write: false is per-grant, not per-actor {: .warning}
  >
  > `write: false` makes a grant carrying that scope never authorize a write —
  > but the actor's other matching grants are still evaluated (scopes
  > OR-compose, issue #123). To hard-block an action for an actor regardless
  > of their other grants, use a `!` deny permission.

  ## Relational Scopes and DB Query Fallback

  Scopes using `exists()` or dot-path references cannot be evaluated in-memory.
  Any write filter with such a reference is verified with a **DB query** instead,
  whether it comes from an inline scope, a `write:` expression, or a legacy
  `scope_resolver`:

  | `write:` value | Strategy | Behavior |
  |---|---|---|
  | `write: false` | Deny | Returns false immediately |
  | `write: true` | Allow | Returns true immediately |
  | `write: expr(...)`, no relationships | In-memory | Evaluate custom expression |
  | `write: expr(...)`, has relationships | **DB query** | Query DB with the `write:` expression |
  | _(omitted, no relationships)_ | In-memory | Evaluate the scope filter |
  | _(omitted, has relationships)_ | **DB query** | Query DB with read scope |
  | legacy `scope_resolver`, has relationships | **DB query** | Query DB with the resolved filter |

  A relationship-bearing filter is never evaluated in memory. If one reaches the
  in-memory path, the check logs a warning and returns false.

  **For update/destroy**: Queries the DB to check if the existing record matches
  the read scope expression.

  **For create**: Splits the filter into direct-attribute parts (evaluated in-memory)
  and relationship parts. Relationship parts are verified by extracting the FK from
  the changeset and querying the parent resource.

  ## Written Values

  An update or destroy is authorized against the record as stored and the
  record as the caller writes it. Some grant must admit each, not necessarily
  the same one, so a write cannot move a record out of every scope the actor
  holds. The written record applies the values the caller supplies: attributes
  the action accepts, attributes a `set_attribute` change fills from an
  argument, a belongs_to foreign key managed with `manage_relationship`, and a
  `resolve_argument` argument resolved again from a written foreign key. A
  value the action sets on its own, such as `:publish` setting `status`, is
  part of what the grant authorizes and is not checked.

  A written value the check cannot compute before the action runs denies the
  write when the scope reads it: an atomic change `Ash.Expr.eval/2` cannot
  evaluate (any `fragment/1`), and a foreign key set through
  `manage_relationship`. A value a `before_action` hook or a custom change sets
  is not seen.

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
  require Logger

  alias AshGrant.Check.WrittenRecord

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

    resource_name = resolve_resource_name(configured_name, opts)
    {action_name, action_type} = resolve_action(action, opts)

    # Build context
    context = build_context(actor, resource_module, action, authorizer)

    grants = resolve_permissions(resolver, actor, context)

    # A ceiling is evaluated as its own permission list; both must authorize.
    resolver
    |> AshGrant.Ceiling.permission_sets(actor, context, grants)
    |> Enum.all?(fn permissions ->
      authorized_by?(permissions, resource_module, resource_name, action_name, action_type, %{
        scope_resolver: scope_resolver,
        context: context,
        authorizer: authorizer,
        opts: opts
      })
    end)
  end

  defp authorized_by?(permissions, resource_module, resource_name, action_name, action_type, env) do
    %{scope_resolver: scope_resolver, context: context, authorizer: authorizer, opts: opts} = env

    AshGrant.PermissionValidation.validate(
      permissions,
      AshGrant.Info.field_group_permissions(resource_module),
      resource: resource_module
    )

    deny_summary =
      AshGrant.Evaluator.deny_summary(permissions, resource_name, action_name, action_type)

    # OR-compose ALL matching grants' scopes (#123): grants are additive, so
    # the action is authorized when ANY grant's scope passes — a narrow grant
    # must never shadow a broader one. `!` deny is the only subtractive device.
    write_scopes =
      if instance_denied?(deny_summary, resource_module, action_type, authorizer, context) do
        :denied
      else
        AshGrant.Evaluator.get_write_scopes(permissions, resource_name, action_name, action_type)
      end

    case write_scopes do
      :unrestricted ->
        true

      {:scopes, [_ | _] = scopes} ->
        stored_and_written?(
          scopes,
          &check_scope_access(&1, scope_resolver, context, authorizer, opts),
          &written_scope_access(&1, scope_resolver, context, opts)
        )

      :denied ->
        # A deny rule matches — deny-wins, never overridden by scope_through (#170).
        false

      {:scopes, []} ->
        # No matching RBAC grant and no deny — try scope_through (parent instance
        # permissions).
        check_scope_through_write(
          resource_module,
          permissions,
          action_name,
          action_type,
          authorizer,
          context
        )
    end
  end

  # Creates and generic actions have no existing record an instance deny could name.
  defp instance_denied?(
         %{denied_instance_ids: []},
         _resource_module,
         _action_type,
         _authorizer,
         _context
       ),
       do: false

  defp instance_denied?(_summary, _resource_module, action_type, _authorizer, _context)
       when action_type in [:create, :action],
       do: false

  defp instance_denied?(
         %{denied_instance_ids: ids},
         resource_module,
         _action_type,
         authorizer,
         context
       ) do
    instance_key = AshGrant.Info.instance_key(resource_module)
    denied_ids = AshGrant.Evaluator.cast_instance_ids(ids, resource_module)

    denied? = fn record ->
      record_id = Map.get(record, instance_key)
      Enum.any?(denied_ids, &instance_id_equal?(resource_module, &1, record_id))
    end

    case get_target_record(authorizer) do
      # Without the record the deny cannot be ruled out, so fail closed.
      nil ->
        true

      record ->
        # An update that rewrites the instance key must not reach a denied id either.
        denied?.(record) or written_instance_denied?(instance_key, context, denied?)
    end
  end

  defp written_instance_denied?(instance_key, context, denied?) do
    case written_state([instance_key], context) do
      :unchanged -> false
      :unknown -> true
      {:changed, record, _arguments} -> denied?.(record)
    end
  end

  defp instance_id_equal?(resource_module, denied_id, record_id) do
    case Ash.Resource.Info.attribute(resource_module, AshGrant.Info.instance_key(resource_module)) do
      nil -> to_string(denied_id) == to_string(record_id)
      %{type: type} -> Ash.Type.equal?(type, denied_id, record_id)
    end
  end

  # Ash passes :resource as the module; we want the string name, and only use a
  # string `resource:` override from opts.
  defp resolve_resource_name(configured_name, opts) do
    case Keyword.get(opts, :resource) do
      nil -> configured_name
      name when is_binary(name) -> name
      _module -> configured_name
    end
  end

  # When the action is overridden via opts, don't infer the action type.
  defp resolve_action(action, opts) do
    case Keyword.get(opts, :action) do
      nil -> {to_string(action.name), action_type_from(action)}
      override -> {override, nil}
    end
  end

  defp check_scope_through_write(
         resource_module,
         permissions,
         action_name,
         action_type,
         authorizer,
         context
       ) do
    record = get_target_record(authorizer)

    parent_grants =
      resource_module
      |> AshGrant.Info.scope_throughs()
      |> Enum.flat_map(
        &scope_through_parent_grant(&1, resource_module, permissions, action_name, action_type)
      )

    record != nil and
      stored_and_written?(
        parent_grants,
        fn {fk_field, parent_ids} -> granted_parent?(record, fk_field, parent_ids) end,
        fn {fk_field, parent_ids} ->
          written_result([fk_field], context, &granted_parent?(&1, fk_field, parent_ids))
        end
      )
  end

  # [{foreign key, granted parent ids}] when the scope_through admits the action.
  defp scope_through_parent_grant(
         scope_through,
         resource_module,
         permissions,
         action_name,
         action_type
       ) do
    if AshGrant.Info.scope_through_allows_action?(scope_through, action_name, action_type) do
      parent_resource_name =
        resource_module |> resolve_parent_resource(scope_through) |> AshGrant.Info.resource_name()

      parent_ids =
        AshGrant.Evaluator.get_matching_instance_ids(
          permissions,
          parent_resource_name,
          action_name,
          action_type
        )

      relationship = Ash.Resource.Info.relationship(resource_module, scope_through.relationship)
      if parent_ids == [], do: [], else: [{relationship.source_attribute, parent_ids}]
    else
      []
    end
  end

  defp granted_parent?(record, fk_field, parent_ids),
    do: to_string(Map.get(record, fk_field)) in parent_ids

  defp resolve_parent_resource(resource_module, scope_through) do
    case scope_through.resource do
      nil ->
        relationship = Ash.Resource.Info.relationship(resource_module, scope_through.relationship)
        relationship.destination

      explicit ->
        explicit
    end
  end

  defp action_type_from(%{type: type}), do: type
  defp action_type_from(_), do: nil

  defp build_context(actor, resource, action, authorizer) do
    %{
      actor: actor,
      resource: resource,
      action: action,
      tenant: get_tenant(authorizer),
      changeset: get_changeset(authorizer),
      query: get_query(authorizer),
      query_context: get_query_context(authorizer)
    }
  end

  # The context `^context(:key)` templates resolve against: the query context on
  # reads, the changeset context on writes. Previously this was never populated
  # on the write path, so `^context(:key)` scopes were silently dropped (#136).
  defp get_query_context(%{query: %{context: context}}) when is_map(context), do: context
  defp get_query_context(%{changeset: %{context: context}}) when is_map(context), do: context
  defp get_query_context(_), do: %{}

  defp resolve_permissions(nil, _actor, %{resource: resource}) do
    raise ArgumentError,
          "AshGrant: no resolver configured for #{inspect(resource)}. " <>
            "Set `resolver` in the resource's `ash_grant` block, on the " <>
            "domain via `AshGrant.Domain`, or app-wide via " <>
            "`config :ash_grant, resolver: MyApp.PermissionResolver`."
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

  defp check_scope_access(scope, _scope_resolver, _context, _authorizer, _opts)
       when scope in ~w(always all global) do
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
    if should_use_db_query?(filter, resource) do
      db_filter = db_query_filter(get_scope_def(resource, scope), scope, filter, context)
      db_query_scope_check(resource, action_type, authorizer, db_filter, context)
    else
      check_scope_in_memory(action_type, filter, context, authorizer, opts)
    end
  end

  # An inline scope without `write:` checks its read filter, as it always has.
  # A `write:` expression or a legacy scope_resolver filter is checked as given.
  defp db_query_filter(%{write: nil}, scope, _filter, context),
    do: resolve_read_scope(context.resource, scope, context)

  defp db_query_filter(_scope_def, _scope, filter, _context), do: filter

  defp check_scope_in_memory(:create, filter, context, _authorizer, opts) do
    case created_record(filter, context) do
      {:ok, record} -> record_matches_filter?(record, filter, context, opts)
      :unknown -> false
    end
  end

  defp check_scope_in_memory(_action_type, filter, context, authorizer, opts) do
    record = get_target_record(authorizer)
    record != nil and record_matches_filter?(record, filter, context, opts)
  end

  defp get_action_type(%{type: type}), do: type
  defp get_action_type(_), do: nil

  # ============================================================
  # Written values
  # ============================================================

  # Grants are additive (#123), on the record as written as much as on the
  # record as stored: some grant must admit each, not necessarily the same one.
  # `written` returns `:unchanged` when the write leaves everything the grant
  # reads as stored, in which case the stored answer stands for it.
  defp stored_and_written?(grants, stored?, written) do
    Enum.any?(grants, stored?) and
      Enum.any?(grants, fn grant ->
        case written.(grant) do
          :unchanged -> stored?.(grant)
          result -> result
        end
      end)
  end

  defp written_scope_access(nil, _scope_resolver, _context, _opts), do: :unchanged

  defp written_scope_access(scope, _scope_resolver, _context, _opts)
       when scope in ~w(always all global),
       do: :unchanged

  defp written_scope_access(scope, scope_resolver, context, opts) do
    resource = context.resource

    case resolve_scope(resource, scope_resolver, scope, context) do
      filter when is_boolean(filter) ->
        :unchanged

      filter ->
        if should_use_db_query?(filter, resource) do
          db_filter = db_query_filter(get_scope_def(resource, scope), scope, filter, context)

          written_result(
            WrittenRecord.referenced(db_filter, resource),
            context,
            &unsaved_record_matches?(resource, &1, db_filter, &2)
          )
        else
          written_result(
            WrittenRecord.referenced(filter, resource),
            context,
            &record_matches_filter?(&1, filter, &2, opts)
          )
        end
    end
  end

  # `:unchanged`, or whether `matches?` admits the record as written. A value
  # that cannot be computed before the action runs denies.
  defp written_result(referenced, context, matches?) when is_function(matches?, 2) do
    case written_state(referenced, context) do
      :unchanged -> :unchanged
      :unknown -> false
      {:changed, record, arguments} -> matches?.(record, Map.put(context, :arguments, arguments))
    end
  end

  defp written_result(referenced, context, matches?) when is_function(matches?, 1),
    do: written_result(referenced, context, fn record, _context -> matches?.(record) end)

  defp written_state(referenced, context) do
    case context[:changeset] do
      %Ash.Changeset{action_type: action_type} = changeset
      when action_type in [:update, :destroy] ->
        WrittenRecord.state(changeset, referenced, context)

      _ ->
        :unchanged
    end
  end

  defp created_record(filter, context) do
    WrittenRecord.created(
      context[:changeset],
      WrittenRecord.referenced(filter, context.resource),
      context
    )
  end

  # ============================================================
  # DB Query Strategy
  # ============================================================

  # Any write filter with relationship references goes to the DB, whether it
  # came from an inline scope, its `write:` expression, or a legacy scope_resolver.
  defp should_use_db_query?(filter, resource) do
    contains_relationship_reference?(filter) and has_data_layer?(resource)
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
    case created_record(read_filter, context) do
      {:ok, record} -> unsaved_record_matches?(resource, record, read_filter, context)
      :unknown -> false
    end
  end

  defp db_query_scope_check(resource, _action_type, authorizer, read_filter, context) do
    record = get_target_record(authorizer)
    record != nil and db_query_record_check(resource, record, read_filter, context)
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

  # A record not stored yet (a create, or an update's written values) cannot be
  # found by primary key. The filter is evaluated over its `and`/`or`/`not`
  # tree with SQL's three-valued logic: relationship-free parts in memory, each
  # relationship part by querying the related resource through the record's
  # foreign key. Any part that cannot be decided denies.
  defp unsaved_record_matches?(resource, record, filter, context) do
    unsaved_eval(resource, record, filter, context) == {:ok, true}
  end

  defp unsaved_eval(resource, record, %Ash.Query.BooleanExpression{} = expr, context) do
    if contains_relationship_reference?(expr) do
      with {:ok, left} <- unsaved_eval(resource, record, expr.left, context),
           {:ok, right} <- unsaved_eval(resource, record, expr.right, context) do
        {:ok, combine(expr.op, left, right)}
      end
    else
      eval_in_memory(record, expr, context)
    end
  end

  defp unsaved_eval(resource, record, %Ash.Query.Not{expression: inner}, context) do
    with {:ok, value} <- unsaved_eval(resource, record, inner, context) do
      {:ok, if(is_nil(value), do: nil, else: not value)}
    end
  end

  defp unsaved_eval(resource, record, filter, context) do
    if contains_relationship_reference?(filter) do
      relationship_leaf(resource, record, filter, context)
    else
      eval_in_memory(record, filter, context)
    end
  end

  defp combine(:and, false, _), do: false
  defp combine(:and, _, false), do: false
  defp combine(:and, true, true), do: true
  defp combine(:and, _, _), do: nil
  defp combine(:or, true, _), do: true
  defp combine(:or, _, true), do: true
  defp combine(:or, false, false), do: false
  defp combine(:or, _, _), do: nil

  defp eval_in_memory(_record, value, _context) when is_boolean(value), do: {:ok, value}

  defp eval_in_memory(record, filter, context) do
    case Ash.Expr.eval(resolve_templates(filter, context),
           record: record,
           resource: context[:resource],
           actor: context[:actor],
           tenant: context[:tenant]
         ) do
      {:ok, value} when is_boolean(value) or is_nil(value) -> {:ok, value}
      _ -> :error
    end
  end

  # exists(rel.rest, inner): query rel's destination through the foreign key.
  defp relationship_leaf(
         resource,
         record,
         %Ash.Query.Exists{path: [rel | rest], expr: inner},
         context
       ) do
    if parent_reference?(inner) do
      :error
    else
      target_filter =
        if rest == [], do: inner, else: %Ash.Query.Exists{path: rest, expr: inner, at_path: []}

      query_related(resource, record, rel, target_filter, context, false)
    end
  end

  # A comparison whose every ref goes through the same first relationship
  # (`team.name == ^actor(:team_name)`): query that relationship's destination.
  defp relationship_leaf(resource, record, expr, context) do
    case single_relationship(expr) do
      {:ok, rel} ->
        transformed = transform_refs_for_target(expr, rel)
        query_related(resource, record, rel, transformed, context, nil)

      :error ->
        :error
    end
  end

  defp query_related(resource, record, rel, target_filter, context, when_no_fk) do
    case Ash.Resource.Info.relationship(resource, rel) do
      nil ->
        :error

      relationship ->
        case Map.get(record, relationship.source_attribute) do
          nil ->
            {:ok, when_no_fk}

          fk_value ->
            relationship.destination
            |> Ash.Query.for_read(:read, %{})
            |> Ash.Query.filter(^[{relationship.destination_attribute, fk_value}])
            |> Ash.Query.filter(^resolve_templates(target_filter, context))
            |> Ash.exists?(exists_opts(context))
            |> then(&{:ok, &1})
        end
    end
  rescue
    error in [Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Framework, ArgumentError] ->
      Logger.warning(
        "AshGrant: could not query #{inspect(rel)} for #{inspect(resource)}: " <>
          Exception.message(error) <> "; failing closed"
      )

      :error
  end

  defp parent_reference?(%Ash.Query.Parent{}), do: true
  defp parent_reference?({:_parent, _}), do: true
  defp parent_reference?({:_parent, _, _}), do: true

  defp parent_reference?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> parent_reference?()

  defp parent_reference?(list) when is_list(list), do: Enum.any?(list, &parent_reference?/1)

  defp parent_reference?(%_{} = struct),
    do: struct |> Map.from_struct() |> Map.values() |> parent_reference?()

  defp parent_reference?(map) when is_map(map), do: map |> Map.values() |> parent_reference?()
  defp parent_reference?(_), do: false

  defp single_relationship(expr) do
    case expr |> relationship_heads() |> Enum.uniq() do
      [rel] when is_atom(rel) -> {:ok, rel}
      _ -> :error
    end
  end

  # The first relationship of every ref in `expr`; `:direct` for a ref to the
  # resource's own attribute and `:other` for anything that is not a plain ref.
  defp relationship_heads(%Ash.Query.Ref{relationship_path: [rel | _]}), do: [rel]
  defp relationship_heads(%Ash.Query.Ref{}), do: [:direct]
  defp relationship_heads(%Ash.Query.Exists{}), do: [:other]
  defp relationship_heads(%Ash.Query.Parent{}), do: [:other]
  defp relationship_heads({:_ref, _, _}), do: [:other]
  defp relationship_heads({:_parent, _}), do: [:other]
  defp relationship_heads({:_parent, _, _}), do: [:other]

  defp relationship_heads(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> relationship_heads()

  defp relationship_heads(list) when is_list(list), do: Enum.flat_map(list, &relationship_heads/1)

  defp relationship_heads(%_{} = struct),
    do: struct |> Map.from_struct() |> Map.values() |> relationship_heads()

  defp relationship_heads(map) when is_map(map), do: map |> Map.values() |> relationship_heads()
  defp relationship_heads(_), do: []

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

  # `:arguments` is set when checking a written record whose arguments
  # `AshGrant.Changes.ResolveArgument` resolved again from a written FK.
  defp extract_arguments(%{arguments: arguments}) when is_map(arguments), do: arguments

  defp extract_arguments(context) do
    case context[:changeset] do
      %{arguments: args} when is_map(args) -> args
      _ -> %{}
    end
  end

  # Transform dot-path refs: remove the first relationship from relationship_path
  defp transform_refs_for_target(expr, rel_name) do
    Ash.Filter.map(expr, fn
      %Ash.Query.Ref{relationship_path: [^rel_name | rest]} = ref ->
        %{ref | relationship_path: rest}

      other ->
        other
    end)
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

  defp record_matches_filter?(record, filter, context, opts) do
    if contains_relationship_reference?(filter) do
      Logger.warning(
        "AshGrant: scope filter #{inspect(filter)} references a relationship and " <>
          "cannot be evaluated in memory on #{inspect(context[:resource])}; failing closed"
      )

      false
    else
      eval_record_filter(record, filter, context, opts)
    end
  end

  defp eval_record_filter(record, filter, context, _opts) do
    actor = context[:actor]
    tenant = context[:tenant]
    resource = context[:resource]

    # Resolve actor/tenant/context/arguments templates to concrete values before
    # eval, then pass resource: so Ash can hydrate attribute references.
    filled =
      Ash.Expr.fill_template(filter,
        actor: actor,
        tenant: tenant,
        context: context[:query_context] || %{},
        args: extract_arguments(context)
      )

    case Ash.Expr.eval(filled, record: record, resource: resource, actor: actor, tenant: tenant) do
      {:ok, true} ->
        true

      {:ok, false} ->
        false

      {:ok, nil} ->
        false

      {:ok, other} ->
        Logger.warning(
          "AshGrant: filter evaluated to a non-boolean value #{inspect(other)}; " <>
            "failing closed"
        )

        false

      :unknown ->
        deny_unevaluable(filter, resource, :unknown)

      {:error, reason} ->
        deny_unevaluable(filter, resource, reason)
    end
  end

  defp deny_unevaluable(filter, resource, reason) do
    Logger.warning(
      "AshGrant: could not evaluate scope filter #{inspect(filter)} on #{inspect(resource)} " <>
        "(#{inspect(reason)}); failing closed"
    )

    false
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

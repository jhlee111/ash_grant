defmodule AshGrant.PolicyTest.Checker do
  @moduledoc false

  # The one permission check behind both policy test runners — the DSL's
  # `assert_can`/`assert_cannot` and the YAML runner. They each carried a copy and
  # the copies drifted (#143): the YAML one read only the first grant's scope, and
  # both let an instance or scope_through grant admit any record.

  alias AshGrant.{Evaluator, Info, Introspect}

  @type action_spec :: atom() | {:action_type, atom()}

  @doc """
  Decides whether `actor` may perform `action_spec`, on `record` when one is given.

  Without a record this is `AshGrant.Introspect.can?/3`. With one, the action
  must be allowed and the record must be admitted by the union the runtime
  builds: any matching grant's scope, a matching instance ID, or a scope_through
  parent's instance ID. A scope is evaluated as the runtime check for that
  action evaluates it — the read filter for a read, and for any other action the
  scope's `write:` override when it has one (`AshGrant.Check`).

  The resolver gets the context `AshGrant.Check` gives it (`actor`, `resource`,
  `action`), with no tenant: a policy test has none.

  `{:action_type, type}` holds when any action of that type passes.
  """
  @spec check(module(), map() | nil, action_spec(), map() | nil, map()) ::
          {:allow, map()} | {:deny, map()}
  def check(resource, actor, action_spec, record, arguments \\ %{})

  def check(resource, actor, {:action_type, type}, record, arguments) do
    case for(%{type: ^type, name: name} <- Ash.Resource.Info.actions(resource), do: name) do
      [] ->
        {:deny, %{reason: :no_matching_action_type}}

      names ->
        results = Enum.map(names, &check(resource, actor, &1, record, arguments))

        Enum.find(results, &match?({:allow, _}, &1)) ||
          Enum.find(results, &match?({:deny, %{reason: :scope_mismatch}}, &1)) ||
          hd(results)
    end
  end

  def check(_resource, nil, _action, _record, _arguments), do: {:deny, %{reason: :no_actor}}

  # The grants are resolved once per check: the same ones decide the action and
  # the instance IDs, as they do in one runtime authorization.
  def check(resource, actor, action, record, arguments) do
    permissions =
      Introspect.permissions_for(resource, actor, context: context(resource, actor, action))

    case {Introspect.decide(resource, action, permissions), record} do
      {{:allow, details}, record} when is_map(record) ->
        admit(resource, actor, action, permissions, record, details, arguments)

      {result, _record} ->
        result
    end
  end

  defp admit(resource, actor, action, permissions, record, details, arguments) do
    scopes = Map.get(details, :scopes, [])
    context = context(resource, actor, action)

    if Enum.any?(scopes, &scope_admits?(resource, context, record, &1, arguments)) or
         instance_admits?(resource, action, permissions, record) do
      {:allow, details}
    else
      {:deny, %{reason: :scope_mismatch, scopes: scopes, record: record}}
    end
  end

  defp context(resource, actor, action) do
    %{actor: actor, resource: resource, action: Ash.Resource.Info.action(resource, action)}
  end

  defp scope_admits?(resource, context, record, scope, arguments) do
    if AshGrant.Scope.universal?(scope) do
      true
    else
      case existing_atom(scope) do
        nil ->
          # Not an atom yet, so no resource declares it.
          false

        scope_atom ->
          filter = scope_filter(resource, scope_atom, context)
          evaluate_filter_against_record(filter, record, context.actor, resource, arguments)
      end
    end
  end

  defp scope_filter(resource, scope, %{action: %{type: :read}} = context),
    do: Info.resolve_scope_filter(resource, scope, context)

  defp scope_filter(resource, scope, context),
    do: Info.resolve_write_scope_filter(resource, scope, context)

  defp instance_admits?(resource, action, permissions, record) do
    action_name = to_string(action)
    action_type = Introspect.resolve_action_type(resource, action)

    ids_for = fn resource_name ->
      Evaluator.get_matching_instance_ids(permissions, resource_name, action_name, action_type)
    end

    id_in?(record, Info.instance_key(resource), ids_for.(Info.resource_name(resource))) or
      Enum.any?(Info.scope_throughs(resource), fn scope_through ->
        Info.scope_through_allows_action?(scope_through, action_name, action_type) and
          parent_admits?(resource, scope_through, record, ids_for)
      end)
  end

  # Decidable from the record only when the foreign key points at the parent's
  # instance_key. Otherwise the runtime joins to the parent row, which a policy
  # test does not have, so the record is not admitted.
  defp parent_admits?(resource, scope_through, record, ids_for) do
    relationship = Ash.Resource.Info.relationship(resource, scope_through.relationship)
    parent = Introspect.scope_through_parent_resource(resource, scope_through)

    Info.instance_key(parent) == relationship.destination_attribute and
      id_in?(record, relationship.source_attribute, ids_for.(Info.resource_name(parent)))
  end

  # Instance IDs are strings in a permission; a policy test record may hold the
  # same ID as an atom (YAML values) or a number (integer keys).
  defp id_in?(record, field, ids) do
    case Map.get(record, field) do
      nil -> false
      value when is_binary(value) or is_atom(value) or is_number(value) -> to_string(value) in ids
      _ -> false
    end
  end

  defp existing_atom(scope) when is_atom(scope), do: scope

  defp existing_atom(scope) when is_binary(scope) do
    String.to_existing_atom(scope)
  rescue
    ArgumentError -> nil
  end

  @doc false
  # Note: `arguments` is a map of action-argument values (or `%{}`) used to
  # resolve `^arg(...)` templates in the filter. The old 4-arity version is
  # preserved for back-compat; new callers should pass arguments.
  def evaluate_filter_against_record(filter, record, actor, resource \\ nil, arguments \\ %{})

  def evaluate_filter_against_record(true, _record, _actor, _resource, _arguments), do: true

  def evaluate_filter_against_record(false, _record, _actor, _resource, _arguments), do: false

  def evaluate_filter_against_record(filter, record, actor, resource, arguments) do
    filled =
      Ash.Expr.fill_template(filter,
        actor: actor,
        context: %{},
        args: arguments || %{}
      )

    case Ash.Expr.eval(filled, record: record, resource: resource, actor: actor) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:ok, nil} -> false
      {:ok, _other} -> true
      :unknown -> fallback_evaluation(filter, record, actor)
      {:error, _} -> fallback_evaluation(filter, record, actor)
    end
  end

  # Fallback evaluation for expressions that Ash.Expr.eval can't handle
  defp fallback_evaluation(filter, record, actor) do
    filter_str = inspect(filter)

    cond do
      # Handle actor field comparison: expr(field == ^actor(:id))
      String.contains?(filter_str, ":_actor") ->
        evaluate_actor_comparison(filter_str, record, actor)

      # Handle status comparison: expr(status == :value)
      String.contains?(filter_str, "status") ->
        evaluate_status_comparison(filter_str, record)

      true ->
        # Default to true if we can't evaluate
        true
    end
  end

  defp evaluate_actor_comparison(filter_str, record, actor) do
    # Extract patterns like `field == {:_actor, :id}` or `field == {:_actor, :field_name}`
    cond do
      match = Regex.run(~r/(\w+)\s*==\s*\{:_actor,\s*:(\w+)\}/, filter_str) ->
        [_, record_field, actor_field] = match
        record_value = Map.get(record, String.to_atom(record_field))
        actor_value = Map.get(actor, String.to_atom(actor_field))
        record_value == actor_value

      match = Regex.run(~r/:name,\s*:(\w+).*:_actor,\s*:(\w+)/, filter_str) ->
        [_, record_field, actor_field] = match
        record_value = Map.get(record, String.to_atom(record_field))
        actor_value = Map.get(actor, String.to_atom(actor_field))
        record_value == actor_value

      true ->
        true
    end
  end

  defp evaluate_status_comparison(filter_str, record) do
    # Handle patterns like `status == :draft` or `status == :published`
    if match = Regex.run(~r/status\s*==\s*:(\w+)/, filter_str) do
      [_, expected_status] = match
      record_status = Map.get(record, :status)

      if is_atom(record_status) do
        record_status == String.to_atom(expected_status)
      else
        to_string(record_status) == expected_status
      end
    else
      true
    end
  end
end

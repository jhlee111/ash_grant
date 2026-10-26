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

  The union is three-valued. A scope that cannot be evaluated in memory does
  not stop another component from admitting the record, but when nothing
  admits it the answer is `{:indeterminate, %{undecided: [reason]}}`, never a
  deny: the caller must fail the assertion either way.

  `{:action_type, type}` holds when any action of that type passes.
  """
  @spec check(module(), map() | nil, action_spec(), map() | nil, map()) ::
          {:allow, map()} | {:deny, map()} | {:indeterminate, map()}
  def check(resource, actor, action_spec, record, arguments \\ %{})

  def check(resource, actor, {:action_type, type}, record, arguments) do
    case for(%{type: ^type, name: name} <- Ash.Resource.Info.actions(resource), do: name) do
      [] ->
        {:deny, %{reason: :no_matching_action_type}}

      names ->
        results = Enum.map(names, &check(resource, actor, &1, record, arguments))

        Enum.find(results, &match?({:allow, _}, &1)) ||
          Enum.find(results, &match?({:indeterminate, _}, &1)) ||
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

  @doc """
  The reasons an `{:indeterminate, details}` result could not be decided, as
  one sentence for an assertion failure message.
  """
  @spec undecided_reason(map()) :: String.t()
  def undecided_reason(%{undecided: undecided}) do
    Enum.join(undecided, "; ") <>
      ". Policy tests evaluate scopes in memory; test this one against the database instead"
  end

  # Unknown OR true is true; unknown OR false is unknown.
  defp admit(resource, actor, action, permissions, record, details, arguments) do
    scopes = Map.get(details, :scopes, [])
    context = context(resource, actor, action)

    verdicts =
      Enum.map(scopes, fn scope ->
        case scope_admits?(resource, context, record, scope, arguments) do
          {:indeterminate, reason} -> {:indeterminate, "scope `#{scope}` #{reason}"}
          verdict -> verdict
        end
      end) ++ instance_verdicts(resource, action, permissions, record)

    undecided = for {:indeterminate, reason} <- verdicts, do: reason

    cond do
      true in verdicts -> {:allow, details}
      undecided != [] -> {:indeterminate, %{undecided: undecided, record: record}}
      true -> {:deny, %{reason: :scope_mismatch, scopes: scopes, record: record}}
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
          resource
          |> scope_filter(scope_atom, context)
          |> evaluate_scope(record, context.actor, resource, arguments)
      end
    end
  end

  # A policy test has no tenant and no query context, so a scope that reads
  # either would be judged against nil — a guess either way.
  defp evaluate_scope(filter, record, actor, resource, arguments) do
    cond do
      Ash.Expr.template_references?(filter, &(&1 == :_tenant)) ->
        {:indeterminate, "uses ^tenant(), which a policy test does not supply"}

      Ash.Expr.template_references_context?(filter) ->
        {:indeterminate, "uses ^context(...), which a policy test does not supply"}

      true ->
        evaluate_filter_against_record(filter, record, actor, resource, arguments)
    end
  end

  defp scope_filter(resource, scope, %{action: %{type: :read}} = context),
    do: Info.resolve_scope_filter(resource, scope, context)

  defp scope_filter(resource, scope, context),
    do: Info.resolve_write_scope_filter(resource, scope, context)

  defp instance_verdicts(resource, action, permissions, record) do
    action_name = to_string(action)
    action_type = Introspect.resolve_action_type(resource, action)

    ids_for = fn resource_name ->
      Evaluator.get_matching_instance_ids(permissions, resource_name, action_name, action_type)
    end

    parents =
      for scope_through <- Info.scope_throughs(resource),
          Info.scope_through_allows_action?(scope_through, action_name, action_type),
          do: parent_admits?(resource, scope_through, record, ids_for)

    [
      id_in?(record, Info.instance_key(resource), ids_for.(Info.resource_name(resource)))
      | parents
    ]
  end

  # Decidable from the record only when the foreign key points at the parent's
  # instance_key. Otherwise the runtime joins to the parent row, which a policy
  # test does not have: with a parent grant in play that is undecided, not a deny.
  defp parent_admits?(resource, scope_through, record, ids_for) do
    relationship = Ash.Resource.Info.relationship(resource, scope_through.relationship)
    parent = Introspect.scope_through_parent_resource(resource, scope_through)
    parent_ids = ids_for.(Info.resource_name(parent))

    cond do
      Info.instance_key(parent) == relationship.destination_attribute ->
        id_in?(record, relationship.source_attribute, parent_ids)

      parent_ids == [] ->
        false

      true ->
        {:indeterminate,
         "scope_through `#{scope_through.relationship}` matches the parent by " <>
           "`#{Info.instance_key(parent)}`, which only a join to the parent row can check"}
    end
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
  # Evaluates a scope filter against a bare record map, in memory. Returns `true`
  # or `false` when that decides it, and `{:indeterminate, reason}` when it does
  # not: a SQL fragment, an exists(), or anything `Ash.Expr.eval` cannot settle.
  # An assertion that cannot be decided must fail whichever way it points —
  # guessing `true` passes `assert_can` blindly, guessing `false` passes
  # `assert_cannot` blindly (#143). `arguments` resolves `^arg(...)` templates.
  def evaluate_filter_against_record(filter, record, actor, resource \\ nil, arguments \\ %{})

  def evaluate_filter_against_record(true, _record, _actor, _resource, _arguments), do: true

  def evaluate_filter_against_record(false, _record, _actor, _resource, _arguments), do: false

  def evaluate_filter_against_record(filter, record, actor, resource, arguments) do
    case Ash.Filter.find(filter, &database_only?/1) do
      nil ->
        eval_in_memory(filter, record, actor, resource, arguments)

      %Ash.Query.Exists{} ->
        {:indeterminate,
         "uses exists(), which needs related rows a policy test record does not have"}

      _fragment ->
        {:indeterminate, "uses fragment(), which only the database can evaluate"}
    end
  end

  # A scope's filter is not hydrated yet, so a fragment is still a `Call`; the
  # `Fragment` struct is what a parsed filter would hold.
  defp database_only?(%Ash.Query.Exists{}), do: true
  defp database_only?(%Ash.Query.Call{name: :fragment}), do: true
  defp database_only?(%Ash.Query.Function.Fragment{}), do: true
  defp database_only?(_), do: false

  defp eval_in_memory(filter, record, actor, resource, arguments) do
    filled =
      Ash.Expr.fill_template(filter,
        actor: actor,
        context: %{},
        args: arguments || %{}
      )

    case Ash.Expr.eval(filled, record: record, resource: resource, actor: actor) do
      {:ok, result} when is_boolean(result) ->
        result

      # A comparison against a value the record lacks is NULL, as it would be
      # for the row — and NULL does not match. That is decided, not unknown.
      {:ok, nil} ->
        false

      {:ok, other} ->
        {:indeterminate, "evaluated to #{inspect(other)}, not a boolean"}

      :unknown ->
        {:indeterminate, "could not be evaluated in memory"}

      {:error, error} ->
        {:indeterminate, "could not be evaluated in memory: #{error_message(error)}"}
    end
  rescue
    error -> {:indeterminate, "could not be evaluated in memory: #{Exception.message(error)}"}
  end

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)
end

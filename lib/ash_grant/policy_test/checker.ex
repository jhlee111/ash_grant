defmodule AshGrant.PolicyTest.Checker do
  @moduledoc false

  # The one permission check behind both policy test runners — the DSL's
  # `assert_can`/`assert_cannot` and the YAML runner. They each carried a copy and
  # the copies drifted (#143): the YAML one read only the first grant's scope, and
  # both let an instance or scope_through grant admit any record.

  alias AshGrant.{Evaluator, Info, Introspect}
  alias AshGrant.PolicyTest.Assertions

  @type action_spec :: atom() | {:action_type, atom()}

  @doc """
  Decides whether `actor` may perform `action_spec`, on `record` when one is given.

  Without a record this is `AshGrant.Introspect.can?/3`. With one, the action
  must be allowed and the record must be admitted by the read-side union the
  runtime builds: any matching grant's scope, a matching instance ID, or a
  scope_through parent's instance ID.

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

  def check(resource, actor, action, nil, _arguments) do
    Introspect.can?(resource, action, actor)
  end

  def check(resource, actor, action, record, arguments) when is_map(record) do
    case Introspect.can?(resource, action, actor) do
      {:allow, details} -> admit(resource, actor, action, record, details, arguments)
      deny -> deny
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
  defp admit(resource, actor, action, record, details, arguments) do
    scopes = Map.get(details, :scopes, [])
    verdicts = Enum.map(scopes, &{&1, scope_admits?(resource, actor, record, &1, arguments)})

    if Enum.any?(verdicts, &(elem(&1, 1) == true)) or
         instance_admits?(resource, actor, action, record) do
      {:allow, details}
    else
      reject(verdicts, scopes, record)
    end
  end

  defp reject(verdicts, scopes, record) do
    case for {scope, {:indeterminate, reason}} <- verdicts, do: "scope `#{scope}` #{reason}" do
      [] -> {:deny, %{reason: :scope_mismatch, scopes: scopes, record: record}}
      undecided -> {:indeterminate, %{undecided: undecided, record: record}}
    end
  end

  defp scope_admits?(resource, actor, record, scope, arguments) do
    if AshGrant.Scope.universal?(scope) do
      true
    else
      case existing_atom(scope) do
        nil ->
          # Not an atom yet, so no resource declares it.
          false

        scope_atom ->
          filter = Info.resolve_scope_filter(resource, scope_atom, %{actor: actor})
          Assertions.evaluate_filter_against_record(filter, record, actor, resource, arguments)
      end
    end
  end

  defp instance_admits?(resource, actor, action, record) do
    permissions = Introspect.permissions_for(resource, actor)
    action_name = to_string(action)
    action_type = action_type(resource, action)

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
    parent = scope_through.resource || relationship.destination

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

  defp action_type(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: type} -> type
      _ -> nil
    end
  end

  defp existing_atom(scope) when is_atom(scope), do: scope

  defp existing_atom(scope) when is_binary(scope) do
    String.to_existing_atom(scope)
  rescue
    ArgumentError -> nil
  end
end

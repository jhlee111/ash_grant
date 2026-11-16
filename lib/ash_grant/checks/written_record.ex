defmodule AshGrant.Check.WrittenRecord do
  @moduledoc false
  # The record an update or destroy writes, as `AshGrant.Check` authorizes it.
  #
  # Only values the caller supplies are applied: attributes the action accepts,
  # attributes a `set_attribute` change fills from an argument, and the foreign
  # key of a belongs_to managed with `manage_relationship`. A value the action
  # sets on its own (`:publish` setting `status`) is part of what the grant
  # authorizes, so the stored value is kept for it.

  require Logger

  @type state ::
          :unchanged
          | :unknown
          | {:changed, record :: map(), arguments :: map()}

  @doc false
  # `referenced` is what the scope reads, from `referenced/2`. `:unchanged`
  # means the write leaves all of it as stored. `:unknown` means a referenced
  # value cannot be computed in memory, which callers deny.
  @spec state(Ash.Changeset.t(), [term()] | :all, map()) :: state()
  def state(%Ash.Changeset{} = changeset, referenced, context) do
    {record, changed, unknown} = apply_changes(changeset, caller_supplied(changeset), context)
    {arguments, changed_arguments, unknown_arguments} = written_arguments(changeset)

    cond do
      touches?(referenced, unknown ++ unknown_arguments) ->
        warn_unknown(context, referenced, unknown ++ unknown_arguments)
        :unknown

      touches?(referenced, changed ++ changed_arguments) ->
        {:changed, record, arguments}

      true ->
        :unchanged
    end
  end

  @doc false
  # The record a create writes: every attribute and atomic change applied.
  @spec created(Ash.Changeset.t() | nil, [term()] | :all, map()) :: {:ok, map()} | :unknown
  def created(nil, _referenced, _context), do: :unknown

  def created(%Ash.Changeset{} = changeset, referenced, context) do
    {record, _changed, unknown} = apply_changes(changeset, :all, context)

    if touches?(referenced, unknown) do
      warn_unknown(context, referenced, unknown)
      :unknown
    else
      {:ok, record}
    end
  end

  defp warn_unknown(context, referenced, unknown) do
    Logger.warning(
      "AshGrant: cannot compute the value #{inspect(context[:resource])} writes to " <>
        "#{inspect(Enum.filter(unknown, &touches?(referenced, [&1])))} in memory; failing closed"
    )
  end

  defp touches?(_referenced, []), do: false
  defp touches?(:all, _keys), do: true
  defp touches?(referenced, keys), do: Enum.any?(keys, &(&1 in referenced))

  # ============================================================
  # Applying changes
  # ============================================================

  defp apply_changes(%Ash.Changeset{data: data} = changeset, supplied, context) do
    data = data || %{}
    {writable, managed} = supplied_attributes(supplied)

    attribute_changes =
      changeset.attributes
      |> Kernel.||(%{})
      |> Enum.filter(fn {attribute, _} -> writable?(writable, attribute) end)

    atomic_changes =
      Enum.filter(changeset.atomics || [], fn {attribute, _} -> writable?(writable, attribute) end)

    {record, unknown} =
      Enum.reduce(atomic_changes, {Map.merge(data, Map.new(attribute_changes)), managed}, fn
        {attribute, expr}, {record, unknown} ->
          case eval_atomic(expr, data, context) do
            {:ok, value} -> {Map.put(record, attribute, value), unknown}
            :error -> {record, [attribute | unknown]}
          end
      end)

    changed =
      for {attribute, _} <- attribute_changes ++ atomic_changes,
          attribute not in unknown,
          not equal?(
            changeset.resource,
            attribute,
            Map.get(record, attribute),
            Map.get(data, attribute)
          ),
          uniq: true,
          do: attribute

    {record, changed, Enum.uniq(unknown)}
  end

  defp supplied_attributes(:all), do: {:all, []}
  defp supplied_attributes({writable, managed}), do: {writable, managed}

  defp writable?(:all, _attribute), do: true
  defp writable?(writable, attribute), do: attribute in writable

  defp equal?(resource, attribute, left, right) do
    case Ash.Resource.Info.attribute(resource, attribute) do
      %{type: type} -> Ash.Type.equal?(type, left, right)
      nil -> left == right
    end
  end

  # An atomic change is computed by the data layer from the stored row, so it
  # is evaluated in memory against the stored record. `Ash.Expr.eval/2` answers
  # `{:ok, nil}` for `fragment/1`, which is not the value the database writes.
  defp eval_atomic(expr, data, context) do
    if fragment?(expr), do: :error, else: do_eval_atomic(expr, data, context)
  end

  defp do_eval_atomic(expr, data, context) do
    filled =
      Ash.Expr.fill_template(expr,
        actor: context[:actor],
        tenant: context[:tenant],
        context: context[:query_context] || %{},
        args: arguments(context[:changeset])
      )

    case Ash.Expr.eval(filled,
           record: data,
           resource: context[:resource],
           actor: context[:actor],
           tenant: context[:tenant]
         ) do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  rescue
    error in [ArgumentError, FunctionClauseError, KeyError, Protocol.UndefinedError] ->
      Logger.debug("AshGrant: atomic change raised #{Exception.message(error)}")
      :error
  end

  defp fragment?(%Ash.Query.Function.Fragment{}), do: true
  defp fragment?(%Ash.Query.Call{name: :fragment}), do: true
  defp fragment?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> fragment?()
  defp fragment?(list) when is_list(list), do: Enum.any?(list, &fragment?/1)
  defp fragment?(%_{} = struct), do: struct |> Map.from_struct() |> Map.values() |> fragment?()
  defp fragment?(map) when is_map(map), do: map |> Map.values() |> fragment?()
  defp fragment?(_), do: false

  defp arguments(%{arguments: arguments}) when is_map(arguments), do: arguments
  defp arguments(_), do: %{}

  # ============================================================
  # Caller-supplied attributes
  # ============================================================

  # {attributes whose written value is applied, attributes whose written value
  # is not known before the action runs}.
  defp caller_supplied(%Ash.Changeset{action: action, resource: resource} = changeset) do
    accepted = Map.get(action || %{}, :accept) || []

    from_arguments =
      for %{change: {Ash.Resource.Change.SetAttribute, opts}} <-
            Map.get(action || %{}, :changes) || [],
          references_argument?(opts[:value]),
          do: opts[:attribute]

    managed =
      for {name, _inputs} <- changeset.relationships || %{},
          %{type: :belongs_to, source_attribute: source_attribute} <-
            [Ash.Resource.Info.relationship(resource, name)],
          do: source_attribute

    {accepted ++ from_arguments, managed}
  end

  defp references_argument?({:_arg, _}), do: true

  defp references_argument?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> references_argument?()

  defp references_argument?(list) when is_list(list), do: Enum.any?(list, &references_argument?/1)

  defp references_argument?(%_{} = struct),
    do: struct |> Map.from_struct() |> Map.values() |> references_argument?()

  defp references_argument?(map) when is_map(map),
    do: map |> Map.values() |> references_argument?()

  defp references_argument?(_), do: false

  # Arguments `AshGrant.Changes.ResolveArgument` resolved a second time from a
  # written foreign key: {all arguments as written, changed, unknown}.
  defp written_arguments(%Ash.Changeset{arguments: arguments} = changeset) do
    written = get_in(changeset.context, [:ash_grant, :written_arguments]) || %{}

    Enum.reduce(written, {arguments || %{}, [], []}, fn
      {name, :unknown}, {args, changed, unknown} ->
        {args, changed, [{:arg, name} | unknown]}

      {name, {:ok, value}}, {args, changed, unknown} ->
        if Map.get(args, name) == value,
          do: {args, changed, unknown},
          else: {Map.put(args, name, value), [{:arg, name} | changed], unknown}
    end)
  end

  # ============================================================
  # References
  # ============================================================

  @doc false
  # The attributes of `resource` a filter reads, plus `{:arg, name}` for each
  # argument. `:all` when that cannot be bounded: a calculation, an aggregate,
  # `parent/1`, or a term this walker does not recognise.
  @spec referenced(term(), Ash.Resource.t()) :: [term()] | :all
  def referenced(filter, resource) do
    refs = collect(filter, resource)
    if :all in refs, do: :all, else: Enum.uniq(refs)
  end

  defp collect(%Ash.Query.Exists{at_path: [relationship | _]}, resource),
    do: [source_attribute(resource, relationship)]

  defp collect(%Ash.Query.Exists{path: [relationship | _], expr: inner}, resource) do
    # Refs inside exists() read the related resource, except parent/1 and arguments.
    [source_attribute(resource, relationship) | nested(inner)]
  end

  defp collect(%Ash.Query.Ref{relationship_path: [relationship | _]}, resource),
    do: [source_attribute(resource, relationship)]

  defp collect(%Ash.Query.Ref{attribute: attribute}, resource),
    do: [attribute_name(resource, attribute)]

  defp collect(%Ash.Query.Parent{}, _resource), do: [:all]
  defp collect({:_arg, name}, _resource), do: [{:arg, name}]
  defp collect({:_ref, [], name}, resource), do: [attribute_name(resource, name)]

  defp collect({:_ref, [relationship | _], _name}, resource),
    do: [source_attribute(resource, relationship)]

  defp collect({:_atomic_ref, name}, resource), do: [attribute_name(resource, name)]
  defp collect({:_parent, _}, _resource), do: [:all]
  defp collect({:_parent, _, _}, _resource), do: [:all]

  defp collect(tuple, resource) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect(resource)

  defp collect(list, resource) when is_list(list), do: Enum.flat_map(list, &collect(&1, resource))

  defp collect(%_{} = struct, resource),
    do: struct |> Map.from_struct() |> Map.values() |> collect(resource)

  defp collect(map, resource) when is_map(map), do: map |> Map.values() |> collect(resource)

  defp collect(value, _resource)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: []

  defp collect(_value, _resource), do: [:all]

  defp nested(%Ash.Query.Parent{}), do: [:all]
  defp nested({:_parent, _}), do: [:all]
  defp nested({:_parent, _, _}), do: [:all]
  defp nested({:_arg, name}), do: [{:arg, name}]
  defp nested(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> nested()
  defp nested(list) when is_list(list), do: Enum.flat_map(list, &nested/1)
  defp nested(%_{} = struct), do: struct |> Map.from_struct() |> Map.values() |> nested()
  defp nested(map) when is_map(map), do: map |> Map.values() |> nested()
  defp nested(_value), do: []

  defp source_attribute(resource, relationship) do
    case Ash.Resource.Info.relationship(resource, relationship) do
      %{source_attribute: source_attribute} -> source_attribute
      nil -> :all
    end
  end

  defp attribute_name(resource, %{name: name}), do: attribute_name(resource, name)

  defp attribute_name(resource, name) when is_atom(name) do
    if Ash.Resource.Info.attribute(resource, name), do: name, else: :all
  end

  defp attribute_name(_resource, _attribute), do: :all
end

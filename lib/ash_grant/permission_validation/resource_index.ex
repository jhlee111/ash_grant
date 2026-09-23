defmodule AshGrant.PermissionValidation.ResourceIndex do
  @moduledoc false
  # The metadata `AshGrant.PermissionValidation.check/2` compares a permission
  # string against, read from the same sources the runtime reads: `AshGrant.Info`
  # for names, scopes and field groups, and `Ash.Resource.Info` for actions.
  #
  # Built once per `check/2` or `check_all/2` call. An entry is a plain map so
  # the checker can pattern-match on it.

  alias AshGrant.Info

  @checks [
    AshGrant.Check,
    AshGrant.FilterCheck,
    AshGrant.FieldCheck,
    AshGrant.FieldFilterCheck,
    AshGrant.Calculation.CanPerform
  ]

  @type entry :: %{
          resource: module(),
          names: [String.t()],
          actions: %{String.t() => atom()},
          through_actions: [{String.t(), atom()}],
          action_overrides: [String.t()],
          scopes: MapSet.t(String.t()),
          scope_resolver?: boolean(),
          field_groups: MapSet.t(String.t())
        }

  @doc """
  Builds the index from `opts`.

  `:resources` wins over `:otp_app`; with neither, every AshGrant resource in
  the started applications' `:ash_domains` is used.
  """
  @spec build(keyword()) :: [entry()]
  def build(opts) do
    resources = opts |> resources() |> Enum.filter(&configured?/1) |> Enum.uniq()
    through = through_actions(resources)

    for resource <- resources do
      resource |> entry() |> Map.put(:through_actions, Map.get(through, resource, []))
    end
  end

  defp resources(opts) do
    cond do
      resources = opts[:resources] ->
        List.wrap(resources)

      otp_app = opts[:otp_app] ->
        domains = Application.get_env(otp_app, :ash_domains, [])
        Enum.flat_map(domains, &Ash.Domain.Info.resources/1)

      true ->
        AshGrant.Introspect.list_resources()
    end
  end

  # A domain-level resolver makes `Info.configured?/1` true for every resource in
  # that domain, so the extension check has to come first.
  defp configured?(resource) do
    AshGrant in Spark.extensions(resource) and Info.configured?(resource)
  rescue
    _ -> false
  end

  # `scope_through` matches the PARENT's instance permissions against the CHILD's
  # action (`get_matching_instance_ids(perms, parent_name, child_action, ...)`),
  # so `post:abc:moderate:` is a live grant when only a child of Post has
  # `moderate`. The `actions:` filter on the entity is ignored here — being
  # lenient costs a missed typo; being strict costs a false error.
  defp through_actions(resources) do
    pairs =
      for child <- resources,
          scope_through <- Info.scope_throughs(child),
          parent = through_parent(child, scope_through),
          action <- Ash.Resource.Info.actions(child),
          do: {parent, {to_string(action.name), action.type}}

    Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
  end

  defp through_parent(child, %{resource: nil, relationship: relationship}) do
    case Ash.Resource.Info.relationship(child, relationship) do
      nil -> nil
      relationship -> relationship.destination
    end
  end

  defp through_parent(_child, %{resource: parent}), do: parent

  defp entry(resource) do
    overrides = overrides(resource)

    %{
      resource: resource,
      names: Enum.uniq([Info.resource_name(resource) | overrides.resources]),
      actions: Map.new(Ash.Resource.Info.actions(resource), &{to_string(&1.name), &1.type}),
      action_overrides: overrides.actions,
      scopes: MapSet.new(Info.scopes(resource), &to_string(&1.name)),
      scope_resolver?: Info.scope_resolver(resource) != nil,
      field_groups: MapSet.new(Info.field_groups(resource), &to_string(&1.name))
    }
  end

  # `AshGrant.check(action: "publish")` and `filter_check(resource: "blog")` make
  # a check match permissions under a name that is neither a real action nor the
  # resource's `resource_name`. Those names are just as valid in a stored string,
  # so they are collected from wherever a check can be declared.
  defp overrides(resource) do
    acc = %{resources: [], actions: []}

    [
      Ash.Policy.Info.policies(resource),
      Ash.Policy.Info.field_policies(resource),
      Ash.Resource.Info.calculations(resource)
    ]
    |> collect(acc)
    |> Map.new(fn {key, names} -> {key, Enum.uniq(names)} end)
  rescue
    # A resource without the policy authorizer has no policies to read.
    _ -> %{resources: [], actions: []}
  end

  # Walks the whole term rather than a known struct shape: policies nest (groups,
  # conditions, bypasses), and the shape is Ash's to change.
  defp collect({module, check_opts}, acc) when module in @checks and is_list(check_opts) do
    if Keyword.keyword?(check_opts) do
      acc
      |> add(:resources, name(check_opts[:resource], :resource))
      |> add(:actions, name(check_opts[:action], :action))
    else
      acc
    end
  end

  defp collect(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> Map.values() |> collect(acc)

  defp collect(map, acc) when is_map(map), do: map |> Map.values() |> collect(acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(tuple, acc) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> collect(acc)
  defp collect(_other, acc), do: acc

  # `resource:` only overrides the name when it is a string — the checks ignore
  # a module there (Ash passes one).
  defp name(value, _key) when is_binary(value), do: value
  defp name(nil, _key), do: nil
  defp name(value, :action) when is_atom(value) and not is_boolean(value), do: to_string(value)
  defp name(_value, _key), do: nil

  defp add(acc, _key, nil), do: acc
  defp add(acc, key, name), do: Map.update!(acc, key, &[name | &1])
end

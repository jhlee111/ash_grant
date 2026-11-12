defmodule AshGrant.InstanceFilter do
  @moduledoc false
  # The instance-permission part of a read filter, shared by `AshGrant.FilterCheck`,
  # `AshGrant.Calculation.CanPerform`, `AshGrant.FieldFilterCheck` and
  # `AshGrant.Explainer` so the four agree on what a scoped instance grant reaches.
  # `AshGrant.Check`, `AshGrant.Introspect` and `AshGrant.PolicyTest.Checker` use
  # `condition/3`, `unconditional?/1` and `reachable?/2` for the same rule.

  require Ash.Expr
  require Logger

  alias AshGrant.Info

  @doc """
  Builds the filter for `{instance_id, scope}` grants, or `nil` when none reach a record.

  An empty or universal scope matches the record by `instance_key` alone. A named
  scope also requires its filter (`instance_key in ^ids and <scope>`). An
  undeclared scope authorizes nothing and does not raise, so a stored grant that
  names a removed scope cannot break reads of the resource. The same holds when a
  legacy `scope_resolver` raises on the scope. `context` is passed to
  `AshGrant.Info.resolve_scope_filter/3`.
  """
  @spec build([{String.t(), String.t() | nil}], Ash.Resource.t(), map()) :: term() | nil
  def build([], _resource, _context), do: nil

  def build(grants, resource, context) do
    key = Ash.Expr.ref(Info.instance_key(resource))

    {unconditional, conditional} =
      grants
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.map(fn {scope, ids} -> {condition(scope, resource, context), Enum.uniq(ids)} end)
      |> Enum.reject(fn {condition, _ids} -> condition == false end)
      |> Enum.split_with(fn {condition, _ids} -> condition == true end)

    unconditional_ids = unconditional |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()

    unconditional_filter =
      if unconditional_ids != [], do: [Ash.Expr.expr(^key in ^unconditional_ids)], else: []

    conditional_filters =
      Enum.map(conditional, fn {condition, ids} ->
        Ash.Expr.expr(^key in ^ids and ^condition)
      end)

    case unconditional_filter ++ conditional_filters do
      [] -> nil
      [first | rest] -> Enum.reduce(rest, first, &Ash.Expr.expr(^&2 or ^&1))
    end
  end

  @doc """
  The condition an instance grant's scope puts on a record of `resource`: `true`
  for an empty or universal scope, `false` for an undeclared one, otherwise the
  scope's read filter. An undeclared scope logs a warning.
  """
  @spec condition(String.t() | nil, Ash.Resource.t(), map()) :: term()
  def condition(nil, _resource, _context), do: true

  def condition(scope, resource, context) do
    name = scope_name(scope)

    cond do
      AshGrant.Scope.universal?(scope) ->
        true

      Info.get_scope(resource, name) ->
        Info.resolve_scope_filter(resource, name, context)

      Info.scope_resolver(resource) ->
        legacy_scope_condition(resource, name, context)

      true ->
        Logger.warning(
          "AshGrant: an instance permission on #{inspect(resource)} names scope " <>
            "#{inspect(scope)}, which the resource does not declare. The grant authorizes " <>
            "nothing. Run `mix ash_grant.check_permissions` to find such grants."
        )

        false
    end
  end

  @doc "Whether an instance grant's scope matches the record by id alone."
  @spec unconditional?(String.t() | nil) :: boolean()
  def unconditional?(scope), do: is_nil(scope) or AshGrant.Scope.universal?(scope)

  @doc """
  Whether an instance grant with this scope can reach any record of `resource`.
  Only an undeclared scope cannot. A legacy `scope_resolver` counts as declaring
  every scope, since only resolving it tells.
  """
  @spec reachable?(String.t() | nil, Ash.Resource.t()) :: boolean()
  def reachable?(scope, resource) do
    unconditional?(scope) or Info.scope_resolver(resource) != nil or
      Info.get_scope(resource, scope_name(scope)) != nil
  end

  # A legacy `scope_resolver` written for RBAC scopes may have no clause for a
  # stale instance grant's scope, or may need context that `CanPerform` does not
  # pass. Its raise authorizes nothing rather than failing every read of the resource.
  defp legacy_scope_condition(resource, name, context) do
    Info.resolve_scope_filter(resource, name, context)
  rescue
    _ -> false
  end

  # Scope names come from permission data, so only an existing atom is used (#143).
  # An undeclared name stays a string, which `resolve_scope_filter/3` resolves to
  # `false` or hands to a legacy `scope_resolver`.
  defp scope_name(scope) do
    String.to_existing_atom(scope)
  rescue
    ArgumentError -> scope
  end
end

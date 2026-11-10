defmodule AshGrant.Ceiling do
  @moduledoc """
  Reads the optional permission ceiling from a resolver and intersects decisions with it.

  A ceiling is the list `c:AshGrant.PermissionResolver.ceiling/2` returns. Every
  AshGrant check evaluates the actor's grants and the ceiling as two separate
  permission lists and authorizes only what both lists authorize, so a deny in
  either list wins.
  """

  require Ash.Expr

  @typedoc "A resolver as returned by `AshGrant.Info.resolver/1`."
  @type resolver :: module() | (term(), map() -> list()) | nil

  @doc """
  Returns the ceiling `resolver` sets for `actor`, or `nil` when it sets none.

  A function resolver, and a module that does not export `ceiling/2`, has no ceiling.
  Raises `ArgumentError` when `ceiling/2` returns anything other than a list or `nil`.
  """
  @spec resolve(resolver(), term(), map()) :: [AshGrant.PermissionResolver.permission()] | nil
  def resolve(resolver, actor, context) when is_atom(resolver) and not is_nil(resolver) do
    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :ceiling, 2) do
      case resolver.ceiling(actor, context) do
        ceiling when is_list(ceiling) or is_nil(ceiling) ->
          ceiling

        other ->
          raise ArgumentError,
                "#{inspect(resolver)}.ceiling/2 must return a list of permissions or nil, " <>
                  "got: #{inspect(other)}"
      end
    end
  end

  def resolve(_resolver, _actor, _context), do: nil

  @doc """
  Returns the permission lists a check must evaluate: the grants, then the ceiling if there is one.

  The action, row, or field is authorized only when every list authorizes it.
  """
  @spec permission_sets(resolver(), term(), map(), list()) :: [list()]
  def permission_sets(resolver, actor, context, grants) do
    case resolve(resolver, actor, context) do
      nil -> [grants]
      ceiling -> [grants, ceiling]
    end
  end

  @doc """
  AND-combines filters built from each permission list.

  Each filter is `true`, `false`, or an Ash expression.
  """
  @spec intersect_filters([boolean() | Ash.Expr.t()]) :: boolean() | Ash.Expr.t()
  def intersect_filters(filters) do
    if false in filters do
      false
    else
      case Enum.reject(filters, &(&1 == true)) do
        [] -> true
        [first | rest] -> Enum.reduce(rest, first, &Ash.Expr.expr(^&2 and ^&1))
      end
    end
  end
end

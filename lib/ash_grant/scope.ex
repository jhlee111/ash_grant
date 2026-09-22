defmodule AshGrant.Scope do
  @moduledoc """
  Helpers for recognizing universal (unrestricted) scope names.

  A universal scope grants access without any record filtering, regardless of
  action type. The built-in universal scope names are `"always"`, `"all"`, and
  `"global"`.

  Centralizing the predicate here keeps the read path (`FilterCheck`,
  `FieldFilterCheck`, `Calculation.CanPerform`) and the write path
  (`AshGrant.Check`) from drifting apart when the set of built-in scopes
  changes (see #139).
  """

  @universal_scopes ["always", "all", "global"]

  @doc """
  Returns `true` if the scope name is a built-in universal scope.

  ## Examples

      iex> AshGrant.Scope.universal?("always")
      true

      iex> AshGrant.Scope.universal?("global")
      true

      iex> AshGrant.Scope.universal?("own")
      false
  """
  @spec universal?(String.t()) :: boolean()
  def universal?(scope) when scope in @universal_scopes, do: true
  def universal?(_scope), do: false
end

defmodule AshGrant.Test.CeilingResolver do
  @moduledoc false
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(%{permissions: permissions}, _context), do: permissions
  def resolve(_actor, _context), do: []

  @impl true
  def ceiling(actor, _context) when is_map(actor), do: Map.get(actor, :ceiling)
  def ceiling(_actor, _context), do: nil
end

defmodule AshGrant.Test.Auth.ResolveCenterIdFromOrder do
  @moduledoc false
  # Lazily populates the :center_id argument from order.center_id.
  #
  # Strategy: inspect the actor's permissions and only perform the DB load if at
  # least one permission's scope expression references `^arg(:center_id)`. This
  # avoids unnecessary preloading when the actor's permissions use scopes that
  # do not need the relationship (e.g. `:by_own_author`, direct attribute).
  #
  # For test observability, writes `:ash_grant_test_loaded_order?` to
  # `changeset.context` so assertions can verify whether the load actually ran.

  use Ash.Resource.Change

  alias AshGrant.Info
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, change_ctx) do
    actor = change_ctx.actor || changeset.context[:private][:actor]

    if needs_center_id?(changeset.resource, actor) do
      loaded = Ash.load!(changeset.data, :order, authorize?: false)

      changeset
      |> Changeset.set_argument(:center_id, loaded.order.center_id)
      |> Changeset.set_context(%{ash_grant_test_loaded_order?: true})
    else
      Changeset.set_context(changeset, %{ash_grant_test_loaded_order?: false})
    end
  end

  defp needs_center_id?(_resource, nil), do: false

  defp needs_center_id?(resource, actor) do
    actor
    |> permissions_for(resource)
    |> Enum.any?(&scope_references_center_id?(resource, &1))
  end

  defp permissions_for(%{permissions: perms}, _resource), do: perms
  defp permissions_for(_, _), do: []

  defp scope_references_center_id?(resource, perm_string) do
    with {:ok, parsed} <- AshGrant.Permission.parse(perm_string),
         true <- match_resource?(resource, parsed.resource),
         scope_atom when is_atom(scope_atom) <- safe_to_atom(parsed.scope),
         filter when filter not in [nil, true, false] <-
           Info.resolve_write_scope_filter(resource, scope_atom, %{}) do
      expression_references_arg?(filter, :center_id)
    else
      _ -> false
    end
  end

  defp match_resource?(_resource, "*"), do: true

  defp match_resource?(resource, name) do
    to_string(Info.resource_name(resource)) == name
  end

  defp safe_to_atom(s) when is_atom(s), do: s

  defp safe_to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  # Walks an Ash expression looking for a template ref {:_arg, name}.
  defp expression_references_arg?({:_arg, name}, name), do: true

  defp expression_references_arg?(%Ash.Query.Call{args: args}, name) do
    Enum.any?(args, &expression_references_arg?(&1, name))
  end

  defp expression_references_arg?(%Ash.Query.BooleanExpression{left: l, right: r}, name) do
    expression_references_arg?(l, name) or expression_references_arg?(r, name)
  end

  defp expression_references_arg?(%Ash.Query.Not{expression: e}, name) do
    expression_references_arg?(e, name)
  end

  defp expression_references_arg?(%{__function__?: true, arguments: args}, name) do
    Enum.any?(args, &expression_references_arg?(&1, name))
  end

  defp expression_references_arg?(%{__struct__: _, left: l, right: r}, name) do
    expression_references_arg?(l, name) or expression_references_arg?(r, name)
  end

  defp expression_references_arg?(list, name) when is_list(list) do
    Enum.any?(list, &expression_references_arg?(&1, name))
  end

  defp expression_references_arg?(_, _), do: false
end

defmodule AshGrant.Changes.ResolveArgument do
  @moduledoc """
  Runtime change that lazily populates an action argument from the record's
  own relationships.

  Installed automatically by `AshGrant.Transformers.AddArgumentResolvers` when a
  resource declares `resolve_argument` in its `ash_grant` block. Users rarely
  reference this module directly.

  ## Options

    * `:name` — argument name to set
    * `:path` — list of atoms walking relationships to a leaf attribute
      (e.g. `[:order, :center_id]`, `[:order, :customer, :organization_id]`).
      Intermediate keys are belongs_to relationships; the last is an attribute.
    * `:scopes_needing` — list of scope atoms whose resolved filter references
      `^arg(<name>)`. Injected by the transformer at compile time.

  ## Runtime contract

  If the actor is nil, or none of the actor's permissions use a scope in
  `:scopes_needing`, the change is a no-op — no DB load is performed.

  Otherwise, the change resolves the path:

    * **create**: read the first-hop foreign key from the changeset's
      attributes, fetch the head record, then walk the remaining path keys
      through loaded relationships.
    * **update/destroy**: load the relationship path on `changeset.data`, then
      read the leaf attribute.

  If any intermediate value is nil or the path cannot be resolved (e.g., the
  referenced record was deleted), the change returns the changeset unchanged —
  the scope will then evaluate against a `nil` argument and typically fail
  closed (authorization denied).

  ## Multi-tenancy

  The changeset's `:tenant` is forwarded to the internal `Ash.get!`/`Ash.load!`
  calls so that resources along `from_path` using attribute multitenancy can be
  fetched correctly. Without this, those fetches would raise, be rescued, and
  leave the argument unset — causing the scope to evaluate to `false`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, opts, ctx) do
    name = Keyword.fetch!(opts, :name)
    path = Keyword.fetch!(opts, :path)
    scopes_needing = Keyword.fetch!(opts, :scopes_needing)

    actor = actor_from_context(ctx, changeset)

    if needs_resolution?(actor, changeset.resource, scopes_needing) do
      case resolve_value(changeset, path) do
        {:ok, value} -> Changeset.set_argument(changeset, name, value)
        :skip -> changeset
      end
    else
      changeset
    end
  end

  defp actor_from_context(%{actor: actor}, _) when not is_nil(actor), do: actor

  defp actor_from_context(_, %{context: context}) when is_map(context) do
    case context do
      %{private: %{actor: actor}} when not is_nil(actor) -> actor
      %{actor: actor} when not is_nil(actor) -> actor
      _ -> nil
    end
  end

  defp actor_from_context(_, _), do: nil

  defp needs_resolution?(nil, _resource, _scopes_needing), do: false
  defp needs_resolution?(_actor, _resource, []), do: false

  defp needs_resolution?(actor, resource, scopes_needing) do
    actor
    |> permissions()
    |> Enum.any?(&permission_uses_listed_scope?(&1, resource, scopes_needing))
  end

  defp permissions(%{permissions: perms}) when is_list(perms), do: perms
  defp permissions(_), do: []

  defp permission_uses_listed_scope?(perm_string, resource, scopes_needing) do
    case AshGrant.Permission.parse(perm_string) do
      {:ok, %{resource: res_name, scope: scope_str}} ->
        resource_matches?(resource, res_name) and
          scope_atom_in?(scope_str, scopes_needing)

      _ ->
        false
    end
  end

  defp resource_matches?(_resource, "*"), do: true

  defp resource_matches?(resource, name) when is_binary(name) do
    to_string(AshGrant.Info.resource_name(resource)) == name
  end

  defp resource_matches?(_, _), do: false

  defp scope_atom_in?(scope_str, scopes) do
    case safe_to_existing_atom(scope_str) do
      nil -> false
      atom -> atom in scopes
    end
  end

  defp safe_to_existing_atom(s) when is_atom(s), do: s

  defp safe_to_existing_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  # --- path resolution ------------------------------------------------------

  defp resolve_value(%{action_type: :create} = cs, [first_rel | rest]) do
    with %{source_attribute: source_attr, destination: destination} <-
           Ash.Resource.Info.relationship(cs.resource, first_rel),
         fk_value when not is_nil(fk_value) <- Changeset.get_attribute(cs, source_attr),
         head when not is_nil(head) <- safe_get(destination, fk_value, tenant_opts(cs)) do
      traverse(head, rest)
    else
      _ -> :skip
    end
  end

  defp resolve_value(cs, path) do
    {rel_path, leaf} = split_relationship_path(cs.resource, path)

    case safe_load(cs.data, build_load(rel_path), tenant_opts(cs)) do
      {:ok, loaded} -> traverse_loaded(loaded, rel_path, leaf)
      :error -> :skip
    end
  end

  # Forward the changeset's tenant so that target resources using attribute
  # multitenancy can be fetched/loaded. Without this, `Ash.get!`/`Ash.load!`
  # raise for attribute-multitenant resources and the change silently skips.
  defp tenant_opts(%{tenant: nil}), do: []
  defp tenant_opts(%{tenant: tenant}), do: [tenant: tenant]
  defp tenant_opts(_), do: []

  # Walk down a path that's already loaded (for create case, we've already
  # loaded the first hop — traverse the rest).
  defp traverse(record, []), do: {:ok, record}

  defp traverse(record, [key | rest]) do
    case Map.get(record, key) do
      nil -> :skip
      %Ash.NotLoaded{} -> :skip
      next -> traverse(next, rest)
    end
  end

  # For update/destroy: we load the relationship chain, then dereference.
  defp traverse_loaded(loaded, rel_path, leaf) do
    case drill(loaded, rel_path) do
      nil -> :skip
      %Ash.NotLoaded{} -> :skip
      record -> {:ok, Map.get(record, leaf)}
    end
  end

  defp drill(record, []), do: record

  defp drill(record, [key | rest]) do
    case Map.get(record, key) do
      nil -> nil
      %Ash.NotLoaded{} -> nil
      next -> drill(next, rest)
    end
  end

  # Split [:order, :center_id] into {rel_path=[:order], leaf=:center_id} by
  # walking relationships until we hit a non-relationship key.
  @doc false
  def split_relationship_path(resource, path) do
    do_split(resource, path, [])
  end

  defp do_split(_resource, [leaf], rel_path), do: {Enum.reverse(rel_path), leaf}

  defp do_split(resource, [key | rest], rel_path) do
    case Ash.Resource.Info.relationship(resource, key) do
      nil ->
        # Key is not a relationship — treat as leaf if nothing follows, else error.
        # (The transformer validates this shape at compile time; at runtime we
        # treat it as a leaf to avoid crashing.)
        if rest == [] do
          {Enum.reverse(rel_path), key}
        else
          {Enum.reverse(rel_path), key}
        end

      %{destination: destination} ->
        do_split(destination, rest, [key | rel_path])
    end
  end

  # Build a load spec usable by Ash.load — [:order] | [order: :customer] | etc.
  defp build_load([]), do: nil
  defp build_load([rel]), do: rel
  defp build_load([rel | rest]), do: [{rel, build_load(rest)}]

  defp safe_get(resource, id, extra_opts) do
    Ash.get!(resource, id, Keyword.merge([authorize?: false], extra_opts))
  rescue
    _ -> nil
  end

  defp safe_load(_data, nil, _extra_opts), do: {:ok, nil}

  defp safe_load(data, load_spec, extra_opts) do
    {:ok, Ash.load!(data, load_spec, Keyword.merge([authorize?: false], extra_opts))}
  rescue
    _ -> :error
  end
end

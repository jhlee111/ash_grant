defmodule AshGrant.CeilingPropertyTest do
  @moduledoc """
  A ceiling intersects with the grants: what an actor may do under grants G and
  ceiling C is exactly what G allows and C allows, each taken as plain grants.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrant.Introspect
  alias AshGrant.Test.CeilingPost

  @actions [:read, :create, :update, :destroy]

  setup do
    actor_id = Ash.UUID.generate()

    posts =
      for author_id <- [actor_id, Ash.UUID.generate()], status <- [:draft, :published] do
        CeilingPost
        |> Ash.Changeset.for_create(:create, %{title: "t", status: status, author_id: author_id})
        |> Ash.create!(authorize?: false)
      end

    %{actor_id: actor_id, posts: posts, post_ids: Enum.map(posts, & &1.id)}
  end

  defp permission_gen(post_ids) do
    gen all(
          deny? <- boolean(),
          instance <- one_of([constant("*"), member_of(post_ids)]),
          action <- member_of(["*", "read", "create", "update", "destroy", "@read", "@update"]),
          scope <- member_of(["always", "own", "published"])
        ) do
      prefix = if deny?, do: "!", else: ""

      if instance == "*",
        do: "#{prefix}ceiling_post:*:#{action}:#{scope}",
        else: "#{prefix}ceiling_post:#{instance}:#{action}:"
    end
  end

  defp readable(actor) do
    case Ash.read(CeilingPost, actor: actor) do
      {:ok, posts} -> MapSet.new(posts, & &1.id)
      {:error, %Ash.Error.Forbidden{}} -> MapSet.new()
    end
  end

  defp allowed?(actor, action),
    do: match?({:allow, _}, Introspect.can?(CeilingPost, action, actor))

  property "reads under a ceiling are the intersection of the two lists' reads", %{
    actor_id: actor_id,
    post_ids: post_ids
  } do
    check all(
            grants <- list_of(permission_gen(post_ids), max_length: 4),
            ceiling <- list_of(permission_gen(post_ids), max_length: 4),
            max_runs: 100
          ) do
      with_ceiling = readable(%{id: actor_id, permissions: grants, ceiling: ceiling})
      grants_only = readable(%{id: actor_id, permissions: grants})
      ceiling_only = readable(%{id: actor_id, permissions: ceiling})

      assert with_ceiling == MapSet.intersection(grants_only, ceiling_only)
      assert MapSet.subset?(with_ceiling, grants_only)
    end
  end

  property "Introspect.can?/4 under a ceiling allows only what both lists allow", %{
    actor_id: actor_id,
    post_ids: post_ids
  } do
    check all(
            grants <- list_of(permission_gen(post_ids), max_length: 4),
            ceiling <- list_of(permission_gen(post_ids), max_length: 4),
            action <- member_of(@actions),
            max_runs: 200
          ) do
      with_ceiling = allowed?(%{id: actor_id, permissions: grants, ceiling: ceiling}, action)
      grants_only = allowed?(%{id: actor_id, permissions: grants}, action)
      ceiling_only = allowed?(%{id: actor_id, permissions: ceiling}, action)

      assert with_ceiling == (grants_only and ceiling_only)
    end
  end

  property "the write check under a ceiling authorizes only what both lists authorize", %{
    actor_id: actor_id,
    posts: posts,
    post_ids: post_ids
  } do
    check all(
            grants <- list_of(permission_gen(post_ids), max_length: 4),
            ceiling <- list_of(permission_gen(post_ids), max_length: 4),
            post <- member_of(posts),
            action <- member_of([:update, :destroy]),
            max_runs: 200
          ) do
      can? = fn actor -> Ash.can?({post, action}, actor) end

      with_ceiling = can?.(%{id: actor_id, permissions: grants, ceiling: ceiling})
      grants_only = can?.(%{id: actor_id, permissions: grants})
      ceiling_only = can?.(%{id: actor_id, permissions: ceiling})

      assert with_ceiling == (grants_only and ceiling_only)
    end
  end
end

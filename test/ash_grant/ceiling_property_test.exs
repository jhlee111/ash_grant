defmodule AshGrant.CeilingPropertyTest do
  @moduledoc """
  A ceiling intersects with the grants: what an actor may do under grants G and
  ceiling C is exactly what G allows and C allows, each taken as plain grants.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Ash.Query

  alias AshGrant.Introspect
  alias AshGrant.Test.CeilingPost

  @actions [:read, :create, :update, :destroy]

  setup do
    actor_id = Ash.UUID.generate()

    posts =
      for author_id <- [actor_id, Ash.UUID.generate()], status <- [:draft, :published] do
        CeilingPost
        |> Ash.Changeset.for_create(:create, %{
          title: "t",
          body: "b",
          notes: "n",
          status: status,
          author_id: author_id
        })
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

  # RBAC grants only. `CanPerform` disagrees with the write check for an
  # instance-only grant without any ceiling, a bug that predates the ceiling.
  defp rbac_permission_gen do
    gen all(
          deny? <- boolean(),
          action <- member_of(["*", "read", "update", "destroy", "@update", "@destroy"]),
          scope <- member_of(["always", "own", "published"])
        ) do
      prefix = if deny?, do: "!", else: ""
      "#{prefix}ceiling_post:*:#{action}:#{scope}"
    end
  end

  defp field_permission_gen do
    gen all(
          deny? <- frequency([{4, constant(false)}, {1, constant(true)}]),
          action <- member_of(["*", "read"]),
          group <- member_of([nil, "summary", "masked", "full"])
        ) do
      # A deny cannot carry a field group.
      if deny?,
        do: "!ceiling_post:*:#{action}:always",
        else: "ceiling_post:*:#{action}:always#{if group, do: ":#{group}", else: ""}"
    end
  end

  # How a read shows `field`: :absent (row not read), :hidden, :masked or :shown.
  defp field_view(actor, post, field) do
    case CeilingPost |> Ash.Query.filter(id == ^post.id) |> Ash.read_one(actor: actor) do
      {:ok, nil} -> :absent
      {:error, %Ash.Error.Forbidden{}} -> :absent
      {:ok, read} -> view_of(Map.fetch!(read, field), Map.fetch!(post, field))
    end
  end

  defp view_of(%Ash.ForbiddenField{}, _original), do: :hidden
  defp view_of(value, value), do: :shown
  defp view_of(_masked, _original), do: :masked

  @view_order [:absent, :hidden, :masked, :shown]
  defp narrower(a, b),
    do: Enum.min_by([a, b], &Enum.find_index(@view_order, fn view -> view == &1 end))

  property "CanPerform agrees with the write check under a ceiling", %{
    actor_id: actor_id,
    posts: posts
  } do
    check all(
            grants <- list_of(rbac_permission_gen(), max_length: 4),
            ceiling <- list_of(rbac_permission_gen(), max_length: 4),
            post <- member_of(posts),
            max_runs: 200
          ) do
      actor = %{id: actor_id, permissions: grants, ceiling: ceiling}

      # authorize?: false skips field policies, which on Elixir 1.18 forbid the
      # generated can_*? calculations (fixed separately).
      loaded =
        CeilingPost
        |> Ash.Query.filter(id == ^post.id)
        |> Ash.read_one!(
          actor: actor,
          authorize?: false,
          load: [:can_update?, :can_destroy?]
        )

      assert loaded.can_update? == Ash.can?({post, :update}, actor)
      assert loaded.can_destroy? == Ash.can?({post, :destroy}, actor)
    end
  end

  property "field visibility under a ceiling is the narrower of the two lists' views", %{
    actor_id: actor_id,
    posts: [post | _]
  } do
    check all(
            grants <- list_of(field_permission_gen(), max_length: 3),
            ceiling <- list_of(field_permission_gen(), max_length: 3),
            field <- member_of([:title, :body, :notes]),
            max_runs: 200
          ) do
      with_ceiling =
        field_view(%{id: actor_id, permissions: grants, ceiling: ceiling}, post, field)

      grants_only = field_view(%{id: actor_id, permissions: grants}, post, field)
      ceiling_only = field_view(%{id: actor_id, permissions: ceiling}, post, field)

      assert with_ceiling == narrower(grants_only, ceiling_only)
    end
  end
end

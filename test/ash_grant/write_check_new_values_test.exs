defmodule AshGrant.WriteCheckNewValuesTest do
  @moduledoc """
  Regression tests: `AshGrant.Check` must authorize an update against the
  record as it will be after the update, not only as it was before.

  A grant whose scope holds on the stored record must not let the actor write a
  value that moves the record out of that scope.
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  require Ash.Expr

  alias AshGrant.Test.BulkItem
  alias AshGrant.Test.BulkMembership
  alias AshGrant.Test.BulkTeam
  alias AshGrant.Test.ChildComment
  alias AshGrant.Test.Post

  defp create_item!(attrs) do
    BulkItem
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_team!(name) do
    BulkTeam
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_membership!(team, user_id) do
    BulkMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: user_id}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_child_comment!(attrs) do
    ChildComment
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp update_as(record, params, actor) do
    record
    |> Ash.Changeset.for_update(:update, params)
    |> Ash.update(actor: actor)
  end

  describe "in-memory scope on a direct attribute" do
    setup do
      actor_id = Ash.UUID.generate()
      actor = %{id: actor_id, permissions: ["item:*:update:own"]}
      item = create_item!(%{title: "Mine", author_id: actor_id})
      %{actor: actor, item: item}
    end

    test "moving the record out of the scope is forbidden", %{actor: actor, item: item} do
      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(item, %{author_id: Ash.UUID.generate()}, actor)
    end

    test "an update that keeps the scoped value in range passes", %{actor: actor, item: item} do
      assert {:ok, %{title: "Renamed"}} = update_as(item, %{title: "Renamed"}, actor)
    end

    test "rewriting the scoped attribute to its current value passes", %{actor: actor, item: item} do
      assert {:ok, _} = update_as(item, %{author_id: actor.id, title: "Same owner"}, actor)
    end

    test "a record outside the scope still cannot be moved into it", %{actor: actor} do
      item = create_item!(%{title: "Theirs", author_id: Ash.UUID.generate()})

      assert {:error, %Ash.Error.Forbidden{}} = update_as(item, %{author_id: actor.id}, actor)
    end
  end

  describe "in-memory scope on an enum attribute" do
    test "a draft-only grant cannot publish the post" do
      actor = %{id: Ash.UUID.generate(), permissions: ["post:*:update:draft"]}
      post = generate(post(title: "Draft", status: :draft))

      assert {:error, %Ash.Error.Forbidden{}} = update_as(post, %{status: :published}, actor)
      assert {:ok, _} = update_as(post, %{title: "Still a draft"}, actor)
    end

    test "a value the action sets itself is part of what the grant authorizes" do
      actor = %{id: Ash.UUID.generate(), permissions: ["post:*:publish:draft"]}
      post = generate(post(title: "Draft", status: :draft))

      assert {:ok, %{status: :published}} =
               post
               |> Ash.Changeset.for_update(:publish, %{})
               |> Ash.update(actor: actor)
    end
  end

  describe "DB-query scope through a relationship" do
    setup do
      actor_id = Ash.UUID.generate()
      actor = %{id: actor_id, permissions: ["item:*:update:team_member"]}
      my_team = create_team!("Mine")
      other_team = create_team!("Other")
      create_membership!(my_team, actor_id)
      item = create_item!(%{title: "Team item", team_id: my_team.id})
      %{actor: actor, item: item, my_team: my_team, other_team: other_team}
    end

    test "moving the record to a team the actor is not in is forbidden", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(ctx.item, %{team_id: ctx.other_team.id}, ctx.actor)
    end

    test "moving the record to another team the actor is in passes", ctx do
      second_team = create_team!("Second")
      create_membership!(second_team, ctx.actor.id)

      assert {:ok, %{team_id: team_id}} =
               update_as(ctx.item, %{team_id: second_team.id}, ctx.actor)

      assert team_id == second_team.id
    end

    test "an update that leaves the FK alone passes", ctx do
      assert {:ok, %{title: "Renamed"}} = update_as(ctx.item, %{title: "Renamed"}, ctx.actor)
    end
  end

  describe "scope_through parent instance grant" do
    setup do
      post = generate(post(title: "Granted"))
      other_post = generate(post(title: "Not granted"))

      comment =
        create_child_comment!(%{body: "Hi", post_id: post.id, user_id: Ash.UUID.generate()})

      actor = %{id: Ash.UUID.generate(), permissions: ["post:#{post.id}:update:"]}
      %{actor: actor, comment: comment, post: post, other_post: other_post}
    end

    test "moving the child under a parent the actor holds no grant on is forbidden", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(ctx.comment, %{post_id: ctx.other_post.id}, ctx.actor)
    end

    test "moving the child between two granted parents passes", ctx do
      actor = %{
        ctx.actor
        | permissions: ctx.actor.permissions ++ ["post:#{ctx.other_post.id}:update:"]
      }

      assert {:ok, %{post_id: post_id}} =
               update_as(ctx.comment, %{post_id: ctx.other_post.id}, actor)

      assert post_id == ctx.other_post.id
    end

    test "an update that leaves the FK alone passes", ctx do
      assert {:ok, %{body: "Edited"}} = update_as(ctx.comment, %{body: "Edited"}, ctx.actor)
    end
  end

  describe "atomic changes" do
    test "an atomic change to a scoped attribute is evaluated against the stored record" do
      actor_id = Ash.UUID.generate()
      actor = %{id: actor_id, permissions: ["item:*:update:own"]}
      item = create_item!(%{title: "Mine", author_id: actor_id})

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{})
               |> Ash.Changeset.atomic_update(:author_id, Ash.UUID.generate())
               |> Ash.update(actor: actor)

      assert {:ok, _} =
               item
               |> Ash.Changeset.for_update(:update, %{})
               |> Ash.Changeset.atomic_update(:author_id, actor_id)
               |> Ash.update(actor: actor)
    end

    test "an atomic change the check cannot evaluate in memory fails closed" do
      actor_id = Ash.UUID.generate()
      actor = %{id: actor_id, permissions: ["item:*:update:own"]}
      item = create_item!(%{title: "Mine", author_id: actor_id})

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{})
               |> Ash.Changeset.atomic_update(
                 :author_id,
                 Ash.Expr.expr(fragment("gen_random_uuid()"))
               )
               |> Ash.update(actor: actor)
    end

    test "an atomic change to an unscoped attribute does not affect the check" do
      actor_id = Ash.UUID.generate()
      actor = %{id: actor_id, permissions: ["item:*:update:own"]}
      item = create_item!(%{title: "Mine", author_id: actor_id})

      assert {:ok, %{team_id: nil}} =
               item
               |> Ash.Changeset.for_update(:update, %{})
               |> Ash.Changeset.atomic_update(:team_id, nil)
               |> Ash.update(actor: actor)
    end
  end

  describe "bulk update" do
    test "a bulk update cannot move records out of the scope" do
      actor_id = Ash.UUID.generate()
      actor = %{id: actor_id, permissions: ["item:*:update:own", "item:*:read:own"]}
      create_item!(%{title: "Mine", author_id: actor_id})

      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_update(:update, %{author_id: Ash.UUID.generate()},
          actor: actor,
          return_errors?: true,
          strategy: [:stream]
        )

      assert result.status == :error
      assert [%{author_id: ^actor_id}] = Ash.read!(BulkItem, authorize?: false)
    end
  end
end

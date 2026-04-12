defmodule AshGrant.ScopeThroughTest do
  @moduledoc """
  Tests for the scope_through feature (#62).

  User Story: As a developer, I want child resources to inherit a parent resource's
  instance permissions via a FK relationship, so that `"post:post_abc:read:"`
  automatically grants access to comments with `post_id == post_abc`.
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Test.ChildComment

  # Helper to create a post in the DB
  defp create_post!(opts) do
    generate(post(opts))
  end

  # Helper to create a child comment in the DB
  defp create_child_comment!(opts) do
    ChildComment
    |> Ash.Changeset.for_create(:create, opts)
    |> Ash.create!(authorize?: false)
  end

  # Helper to read child comments with actor
  defp read_comments(actor) do
    ChildComment
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: actor)
  end

  describe "scope_through :post — read filtering (parent instance propagation)" do
    test "parent instance permission grants access to child records" do
      post = create_post!(title: "My Post", author_id: Ash.UUID.generate())

      comment_in_post =
        create_child_comment!(%{body: "In post", post_id: post.id, user_id: Ash.UUID.generate()})

      _comment_elsewhere =
        create_child_comment!(%{
          body: "Elsewhere",
          post_id: Ash.UUID.generate(),
          user_id: Ash.UUID.generate()
        })

      actor = %{id: Ash.UUID.generate(), permissions: ["post:#{post.id}:read:"]}

      comments = read_comments(actor)
      assert length(comments) == 1
      assert hd(comments).id == comment_in_post.id
    end

    test "multiple parent instance permissions see all related children" do
      post1 = create_post!(title: "Post 1", author_id: Ash.UUID.generate())
      post2 = create_post!(title: "Post 2", author_id: Ash.UUID.generate())

      c1 =
        create_child_comment!(%{body: "C1", post_id: post1.id, user_id: Ash.UUID.generate()})

      c2 =
        create_child_comment!(%{body: "C2", post_id: post2.id, user_id: Ash.UUID.generate()})

      _c3 =
        create_child_comment!(%{
          body: "C3",
          post_id: Ash.UUID.generate(),
          user_id: Ash.UUID.generate()
        })

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["post:#{post1.id}:read:", "post:#{post2.id}:read:"]
      }

      comments = read_comments(actor)
      assert length(comments) == 2
      ids = Enum.map(comments, & &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "parent deny blocks child access" do
      post = create_post!(title: "Denied Post", author_id: Ash.UUID.generate())

      _comment =
        create_child_comment!(%{body: "Denied", post_id: post.id, user_id: Ash.UUID.generate()})

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["post:#{post.id}:read:", "!post:#{post.id}:read:"]
      }

      result = ChildComment |> Ash.Query.for_read(:read) |> Ash.read(actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "combined RBAC + parent instance permissions (OR logic)" do
      actor_id = Ash.UUID.generate()
      post = create_post!(title: "Specific Post", author_id: Ash.UUID.generate())

      # Comment in the specific post (accessible via parent instance)
      c_in_post =
        create_child_comment!(%{body: "In post", post_id: post.id, user_id: Ash.UUID.generate()})

      # Own comment in another post (accessible via RBAC :own)
      c_own =
        create_child_comment!(%{
          body: "My comment",
          post_id: Ash.UUID.generate(),
          user_id: actor_id
        })

      # Someone else's comment in another post (not accessible)
      _c_other =
        create_child_comment!(%{
          body: "Other",
          post_id: Ash.UUID.generate(),
          user_id: Ash.UUID.generate()
        })

      actor = %{
        id: actor_id,
        permissions: ["child_comment:*:read:own", "post:#{post.id}:read:"]
      }

      comments = read_comments(actor)
      assert length(comments) == 2
      ids = Enum.map(comments, & &1.id)
      assert c_in_post.id in ids
      assert c_own.id in ids
    end

    test "non-matching parent permissions return empty results" do
      post = create_post!(title: "Some Post", author_id: Ash.UUID.generate())

      _comment =
        create_child_comment!(%{body: "Hello", post_id: post.id, user_id: Ash.UUID.generate()})

      # Actor has parent instance for a different post — filter won't match
      actor = %{id: Ash.UUID.generate(), permissions: ["post:#{Ash.UUID.generate()}:read:"]}

      comments = read_comments(actor)
      assert comments == []
    end

    test "no permissions at all returns forbidden" do
      post = create_post!(title: "Some Post", author_id: Ash.UUID.generate())

      _comment =
        create_child_comment!(%{body: "Hello", post_id: post.id, user_id: Ash.UUID.generate()})

      actor = %{id: Ash.UUID.generate(), permissions: []}

      result = ChildComment |> Ash.Query.for_read(:read) |> Ash.read(actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "scope_through :post — write actions" do
    test "parent instance permission allows update on matching post" do
      post = create_post!(title: "My Post", author_id: Ash.UUID.generate())

      comment =
        create_child_comment!(%{body: "Original", post_id: post.id, user_id: Ash.UUID.generate()})

      actor = %{id: Ash.UUID.generate(), permissions: ["post:#{post.id}:update:"]}

      result =
        comment
        |> Ash.Changeset.for_update(:update, %{body: "Updated"})
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.body == "Updated"
    end

    test "parent instance permission denies update on non-matching post" do
      other_post_id = Ash.UUID.generate()
      post = create_post!(title: "Different Post", author_id: Ash.UUID.generate())

      comment =
        create_child_comment!(%{body: "Original", post_id: post.id, user_id: Ash.UUID.generate()})

      # Actor has update permission for a different post
      actor = %{id: Ash.UUID.generate(), permissions: ["post:#{other_post_id}:update:"]}

      result =
        comment
        |> Ash.Changeset.for_update(:update, %{body: "Hacked"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "scope_through :post — CanPerform calculation" do
    test "can_update? reflects parent instance permissions" do
      post1 = create_post!(title: "Post 1", author_id: Ash.UUID.generate())
      post2 = create_post!(title: "Post 2", author_id: Ash.UUID.generate())

      c1 =
        create_child_comment!(%{
          body: "In post1",
          post_id: post1.id,
          user_id: Ash.UUID.generate()
        })

      c2 =
        create_child_comment!(%{
          body: "In post2",
          post_id: post2.id,
          user_id: Ash.UUID.generate()
        })

      # Actor can read all (RBAC) but only update post1's children
      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["child_comment:*:read:always", "post:#{post1.id}:update:"]
      }

      comments =
        ChildComment
        |> Ash.Query.for_read(:read)
        |> Ash.Query.load([:can_update?])
        |> Ash.read!(actor: actor)

      comments_by_id = Map.new(comments, &{&1.id, &1})
      assert comments_by_id[c1.id].can_update? == true
      assert comments_by_id[c2.id].can_update? == false
    end
  end
end

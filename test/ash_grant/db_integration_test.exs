defmodule AshGrant.DbIntegrationTest do
  @moduledoc """
  Database integration tests that verify AshGrant works correctly with
  actual database queries.

  These tests ensure the Scope DSL → Ash Filter → SQL Query pipeline
  works end-to-end with real data.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.Post

  # === Test Actors ===

  defp admin_actor do
    %{id: Ash.UUID.generate(), role: :admin}
  end

  defp editor_actor(id) do
    %{id: id, role: :editor}
  end

  defp viewer_actor do
    %{id: Ash.UUID.generate(), role: :viewer}
  end

  defp custom_perms_actor(perms, id) do
    %{id: id, permissions: perms}
  end

  # === Helper Functions ===

  defp create_post!(attrs) do
    Post
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp read_posts(actor) do
    Post
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: actor)
  end

  # === Tests ===

  describe "scope :all - returns all records" do
    test "admin with 'all' scope can read all posts" do
      # Create test data
      author1 = Ash.UUID.generate()
      author2 = Ash.UUID.generate()

      post1 = create_post!(%{title: "Post 1", status: :draft, author_id: author1})
      post2 = create_post!(%{title: "Post 2", status: :published, author_id: author1})
      post3 = create_post!(%{title: "Post 3", status: :draft, author_id: author2})
      post4 = create_post!(%{title: "Post 4", status: :published, author_id: author2})

      # Admin should see all 4 posts
      admin = admin_actor()
      posts = read_posts(admin)

      assert length(posts) == 4
      ids = Enum.map(posts, & &1.id)
      assert post1.id in ids
      assert post2.id in ids
      assert post3.id in ids
      assert post4.id in ids
    end
  end

  describe "scope :published - filters by status" do
    test "viewer with 'published' scope only sees published posts" do
      author = Ash.UUID.generate()

      _draft1 = create_post!(%{title: "Draft 1", status: :draft, author_id: author})
      published1 = create_post!(%{title: "Published 1", status: :published, author_id: author})
      _draft2 = create_post!(%{title: "Draft 2", status: :draft, author_id: author})
      published2 = create_post!(%{title: "Published 2", status: :published, author_id: author})

      # Viewer should only see published posts
      viewer = viewer_actor()
      posts = read_posts(viewer)

      assert length(posts) == 2
      ids = Enum.map(posts, & &1.id)
      assert published1.id in ids
      assert published2.id in ids
    end
  end

  describe "scope :own - filters by actor ID" do
    test "editor with 'own' scope for update only sees own posts for read (all scope)" do
      editor_id = Ash.UUID.generate()
      other_author = Ash.UUID.generate()

      _own_post = create_post!(%{title: "My Post", status: :draft, author_id: editor_id})
      _other_post = create_post!(%{title: "Other Post", status: :draft, author_id: other_author})

      editor = editor_actor(editor_id)

      # Editor has "post:*:read:all" so should see all posts
      posts = read_posts(editor)
      assert length(posts) == 2
    end

    @tag :skip
    # Skipped: Check module's record matching for "own" scope needs improvement
    # The changeset.data is %Post{author_id: nil} before the record is loaded
    test "editor can update own post" do
      editor_id = Ash.UUID.generate()

      own_post = create_post!(%{title: "My Post", status: :draft, author_id: editor_id})

      editor = editor_actor(editor_id)

      # Editor has "post:*:update:own" - verify by trying to update
      result =
        own_post
        |> Ash.Changeset.for_update(:update, %{title: "Updated"})
        |> Ash.update(actor: editor)

      assert {:ok, updated} = result
      assert updated.title == "Updated"
    end

    @tag :skip
    # Skipped: See above - Check module's record matching needs improvement
    test "editor cannot update other's post" do
      editor_id = Ash.UUID.generate()
      other_author = Ash.UUID.generate()

      other_post = create_post!(%{title: "Other Post", status: :draft, author_id: other_author})

      editor = editor_actor(editor_id)

      # Editor should not be able to update someone else's post
      result =
        other_post
        |> Ash.Changeset.for_update(:update, %{title: "Hacked"})
        |> Ash.update(actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "scope :own_draft - inherited scope combining :own and :draft filter" do
    test "actor with own_draft scope only sees own draft posts" do
      actor_id = Ash.UUID.generate()
      other_author = Ash.UUID.generate()

      own_draft = create_post!(%{title: "My Draft", status: :draft, author_id: actor_id})

      _own_published =
        create_post!(%{title: "My Published", status: :published, author_id: actor_id})

      _other_draft =
        create_post!(%{title: "Other Draft", status: :draft, author_id: other_author})

      _other_published =
        create_post!(%{title: "Other Published", status: :published, author_id: other_author})

      # Actor with own_draft permission
      actor = custom_perms_actor(["post:*:read:own_draft"], actor_id)
      posts = read_posts(actor)

      # Should only see own draft (inherited: own AND draft)
      assert length(posts) == 1
      assert hd(posts).id == own_draft.id
    end
  end

  describe "multiple scopes combined with OR" do
    test "actor with multiple read scopes gets union of results" do
      actor_id = Ash.UUID.generate()
      other_author = Ash.UUID.generate()

      own_draft = create_post!(%{title: "My Draft", status: :draft, author_id: actor_id})

      own_published =
        create_post!(%{title: "My Published", status: :published, author_id: actor_id})

      _other_draft =
        create_post!(%{title: "Other Draft", status: :draft, author_id: other_author})

      other_published =
        create_post!(%{title: "Other Published", status: :published, author_id: other_author})

      # Actor with both own and published scopes
      actor = custom_perms_actor(["post:*:read:own", "post:*:read:published"], actor_id)
      posts = read_posts(actor)

      # Should see: own posts (draft + published) OR published posts (own + other)
      # = own_draft, own_published, other_published (3 posts)
      assert length(posts) == 3
      ids = Enum.map(posts, & &1.id)
      assert own_draft.id in ids
      assert own_published.id in ids
      assert other_published.id in ids
    end
  end

  describe "deny-wins with database" do
    test "deny permission blocks access even when allow exists" do
      actor_id = Ash.UUID.generate()

      _post = create_post!(%{title: "Test Post", status: :published, author_id: actor_id})

      # Actor has all access but deny for delete
      actor =
        custom_perms_actor(
          [
            "post:*:*:all",
            "!post:*:destroy:all"
          ],
          actor_id
        )

      # Can read
      posts = read_posts(actor)
      assert length(posts) == 1

      # Cannot destroy (denied)
      result =
        hd(posts)
        |> Ash.Changeset.for_destroy(:destroy)
        |> Ash.destroy(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "scope :today - temporal filtering with SQL fragment" do
    test "today scope only returns records created today" do
      actor_id = Ash.UUID.generate()

      # Create a post (will have today's inserted_at)
      today_post = create_post!(%{title: "Today Post", status: :draft, author_id: actor_id})

      # Actor with today scope
      actor = custom_perms_actor(["post:*:read:today"], actor_id)
      posts = read_posts(actor)

      # Should see the post created today
      assert length(posts) == 1
      assert hd(posts).id == today_post.id
    end
  end

  describe "nil actor - no permissions" do
    test "nil actor cannot read any posts" do
      _post =
        create_post!(%{title: "Test Post", status: :published, author_id: Ash.UUID.generate()})

      # nil actor should get forbidden
      result =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.read(actor: nil)

      # With authorize?: true (default), nil actor with no permissions gets forbidden
      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "instance permissions" do
    @tag :skip
    # Skipped: Instance permissions in FilterCheck need to generate
    # id == specific_id filters - not yet implemented
    test "instance permission grants access to specific record" do
      author = Ash.UUID.generate()
      actor_id = Ash.UUID.generate()

      post1 = create_post!(%{title: "Post 1", status: :draft, author_id: author})
      _post2 = create_post!(%{title: "Post 2", status: :draft, author_id: author})

      # Actor has instance permission for post1 only
      # Format: resource:instance_id:action:
      actor = custom_perms_actor(["post:#{post1.id}:read:"], actor_id)

      # This should work for instance permissions
      # Note: Instance permissions require the check to handle them
      posts = read_posts(actor)

      # With current implementation, should only see post1
      assert length(posts) == 1
      assert hd(posts).id == post1.id
    end
  end
end

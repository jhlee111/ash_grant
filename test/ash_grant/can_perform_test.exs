defmodule AshGrant.CanPerformTest do
  @moduledoc """
  Tests for AshGrant.Calculation.CanPerform.

  Verifies that the calculation produces correct per-record boolean values
  by mirroring FilterCheck's permission resolution logic.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.Post
  alias AshGrant.Test.SharedDoc

  # === Actors ===

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

  # === Helpers ===

  defp create_post!(attrs) do
    Post
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_shared_doc!(title, owner_id) do
    SharedDoc
    |> Ash.Changeset.for_create(:create, %{title: title, owner_id: owner_id}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp read_posts_with_calcs(actor, calcs \\ [:can_update?, :can_destroy?]) do
    Post
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load(calcs)
    |> Ash.read!(actor: actor)
  end

  # === Tests ===

  describe "basic RBAC" do
    test "admin (all scope) gets true for all records" do
      author = Ash.UUID.generate()
      create_post!(%{title: "Post 1", status: :draft, author_id: author})
      create_post!(%{title: "Post 2", status: :published, author_id: author})

      posts = read_posts_with_calcs(admin_actor())

      assert [_, _] = posts
      assert Enum.all?(posts, & &1.can_update?)
      assert Enum.all?(posts, & &1.can_destroy?)
    end

    test "editor (own scope) gets true only for own records" do
      editor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      own_post = create_post!(%{title: "My Post", status: :draft, author_id: editor_id})
      _other_post = create_post!(%{title: "Other Post", status: :published, author_id: other_id})

      posts = read_posts_with_calcs(editor_actor(editor_id))
      posts_by_id = Map.new(posts, &{&1.id, &1})

      # Editor has post:*:update:own — can_update? true only for own
      own = posts_by_id[own_post.id]
      assert own.can_update? == true

      # Editor can read all (read:always) but can only update own
      # Other post visible due to read:always, but can_update? false
      other_posts = Enum.reject(posts, &(&1.id == own_post.id))

      for post <- other_posts do
        assert post.can_update? == false
      end
    end

    test "viewer (no update permission) gets false for all records" do
      author = Ash.UUID.generate()
      create_post!(%{title: "Post 1", status: :published, author_id: author})

      posts = read_posts_with_calcs(viewer_actor())

      assert posts != []
      assert Enum.all?(posts, &(&1.can_update? == false))
      assert Enum.all?(posts, &(&1.can_destroy? == false))
    end
  end

  describe "no actor" do
    test "nil actor produces false" do
      # CanPerform with nil actor returns false
      # But reading without actor will be forbidden by policies,
      # so we test the calculation module directly
      assert AshGrant.Calculation.CanPerform.expression(
               [action: "update", resource: Post],
               %Ash.Resource.Calculation.Context{
                 actor: nil,
                 tenant: nil,
                 source_context: %{}
               }
             ) == false
    end
  end

  describe "deny-wins" do
    test "deny permission overrides allow" do
      author_id = Ash.UUID.generate()
      create_post!(%{title: "Post 1", status: :published, author_id: author_id})

      # Actor has update:always but also !update:always → deny wins
      actor =
        custom_perms_actor(
          ["post:*:read:always", "post:*:update:always", "!post:*:update:always"],
          author_id
        )

      posts = read_posts_with_calcs(actor)

      assert posts != []
      assert Enum.all?(posts, &(&1.can_update? == false))
    end
  end

  describe "multi-scope combination" do
    test "multiple scopes combined with OR" do
      editor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      own_draft = create_post!(%{title: "My Draft", status: :draft, author_id: editor_id})

      published_other =
        create_post!(%{title: "Other Published", status: :published, author_id: other_id})

      draft_other = create_post!(%{title: "Other Draft", status: :draft, author_id: other_id})

      # Actor can update own OR published
      actor =
        custom_perms_actor(
          ["post:*:read:always", "post:*:update:own", "post:*:update:published"],
          editor_id
        )

      posts = read_posts_with_calcs(actor, [:can_update?])
      posts_by_id = Map.new(posts, &{&1.id, &1})

      # own_draft: matches :own scope (author_id == actor.id)
      assert posts_by_id[own_draft.id].can_update? == true
      # published_other: matches :published scope (status == :published)
      assert posts_by_id[published_other.id].can_update? == true
      # draft_other: matches neither :own nor :published
      assert posts_by_id[draft_other.id].can_update? == false
    end
  end

  describe "instance permissions with SharedDoc" do
    test "guest with instance permissions gets true for shared docs" do
      doc1 = create_shared_doc!("Doc 1", "owner-1")
      doc2 = create_shared_doc!("Doc 2", "owner-2")
      _doc3 = create_shared_doc!("Doc 3", "owner-3")

      # Guest only has instance read permission, no update instance permissions
      actor = %{id: "reader-1", role: :guest, shared_doc_ids: [doc1.id, doc2.id]}

      docs =
        SharedDoc
        |> Ash.Query.load([:can_update?])
        |> Ash.read!(actor: actor)

      # Guest only has read instance perms, no update perms → can_update? false
      assert Enum.all?(docs, &(&1.can_update? == false))
    end

    test "owner with RBAC update:own gets true for own docs" do
      doc1 = create_shared_doc!("Doc 1", "owner-1")
      doc2 = create_shared_doc!("Doc 2", "owner-1")
      doc3 = create_shared_doc!("Doc 3", "owner-2")

      # User owns doc1 and doc2 via RBAC, has instance read for doc3
      actor = %{id: "owner-1", role: :user, shared_doc_ids: [doc3.id]}

      docs =
        SharedDoc
        |> Ash.Query.load([:can_update?])
        |> Ash.read!(actor: actor)

      docs_by_id = Map.new(docs, &{&1.id, &1})

      # Own docs: can_update? true (RBAC update:own)
      assert docs_by_id[doc1.id].can_update? == true
      assert docs_by_id[doc2.id].can_update? == true
      # Shared doc: can_update? false (only has read instance perm)
      assert docs_by_id[doc3.id].can_update? == false
    end
  end

  describe "init/1" do
    test "requires action option" do
      assert {:error, _} = AshGrant.Calculation.CanPerform.init(resource: Post)
    end

    test "requires resource option" do
      assert {:error, _} = AshGrant.Calculation.CanPerform.init(action: "update")
    end

    test "accepts action and resource options" do
      assert {:ok, opts} = AshGrant.Calculation.CanPerform.init(action: "update", resource: Post)
      assert opts[:action] == "update"
      assert opts[:resource] == Post
    end
  end

  describe "describe/1" do
    test "returns descriptive string" do
      assert AshGrant.Calculation.CanPerform.describe(action: "update") ==
               "can_perform(update)"
    end
  end
end

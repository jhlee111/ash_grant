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

    # Previously skipped - now works with improved Check module
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

    # Previously skipped - now works with improved Check module
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
    test "today scope only returns records created today (using injectable scope)" do
      actor_id = Ash.UUID.generate()

      # Create a post (will have today's inserted_at)
      today_post = create_post!(%{title: "Today Post", status: :draft, author_id: actor_id})

      # Get the actual date of the post
      post_date = DateTime.to_date(today_post.inserted_at)

      # Actor with today_injectable scope (uses context injection)
      actor = custom_perms_actor(["post:*:read:today_injectable"], actor_id)

      # Pass the reference date via query context
      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{reference_date: post_date})
        |> Ash.read!(actor: actor)

      # Should see the post created on that date
      assert length(posts) == 1
      assert hd(posts).id == today_post.id
    end

    test "today_injectable scope excludes records from different dates" do
      actor_id = Ash.UUID.generate()

      # Create a post
      _post = create_post!(%{title: "Test Post", status: :draft, author_id: actor_id})

      # Actor with today_injectable scope
      actor = custom_perms_actor(["post:*:read:today_injectable"], actor_id)

      # Pass yesterday's date - should NOT match
      yesterday = Date.add(Date.utc_today(), -1)

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{reference_date: yesterday})
        |> Ash.read!(actor: actor)

      # Should NOT see any posts
      assert length(posts) == 0
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

  describe "scope :business_hours_injectable - hour-based filtering with EXTRACT fragment" do
    test "business_hours_injectable scope returns posts during business hours (10:00)" do
      actor_id = Ash.UUID.generate()

      # Create a post
      post = create_post!(%{title: "Business Hours Post", status: :draft, author_id: actor_id})

      # Actor with business_hours_injectable scope
      actor = custom_perms_actor(["post:*:read:business_hours_injectable"], actor_id)

      # Pass a timestamp during business hours (10:00 AM)
      business_hour_time = ~N[2024-01-15 10:00:00]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: business_hour_time})
        |> Ash.read!(actor: actor)

      # Should see the post (10 is between 9 and 17)
      assert length(posts) == 1
      assert hd(posts).id == post.id
    end

    test "business_hours_injectable scope returns posts during business hours (17:00)" do
      actor_id = Ash.UUID.generate()

      # Create a post
      post = create_post!(%{title: "Late Business Post", status: :draft, author_id: actor_id})

      # Actor with business_hours_injectable scope
      actor = custom_perms_actor(["post:*:read:business_hours_injectable"], actor_id)

      # Pass a timestamp at end of business hours (5:00 PM)
      business_hour_time = ~N[2024-01-15 17:00:00]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: business_hour_time})
        |> Ash.read!(actor: actor)

      # Should see the post (17 is included in BETWEEN 9 AND 17)
      assert length(posts) == 1
      assert hd(posts).id == post.id
    end

    test "business_hours_injectable scope excludes posts outside business hours (early morning)" do
      actor_id = Ash.UUID.generate()

      # Create a post
      _post = create_post!(%{title: "Early Post", status: :draft, author_id: actor_id})

      # Actor with business_hours_injectable scope
      actor = custom_perms_actor(["post:*:read:business_hours_injectable"], actor_id)

      # Pass a timestamp before business hours (6:00 AM)
      early_time = ~N[2024-01-15 06:00:00]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: early_time})
        |> Ash.read!(actor: actor)

      # Should NOT see any posts (6 is not between 9 and 17)
      assert length(posts) == 0
    end

    test "business_hours_injectable scope excludes posts outside business hours (late night)" do
      actor_id = Ash.UUID.generate()

      # Create a post
      _post = create_post!(%{title: "Night Post", status: :draft, author_id: actor_id})

      # Actor with business_hours_injectable scope
      actor = custom_perms_actor(["post:*:read:business_hours_injectable"], actor_id)

      # Pass a timestamp after business hours (10:00 PM / 22:00)
      late_time = ~N[2024-01-15 22:00:00]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: late_time})
        |> Ash.read!(actor: actor)

      # Should NOT see any posts (22 is not between 9 and 17)
      assert length(posts) == 0
    end

    test "business_hours_injectable scope boundary test at hour 9" do
      actor_id = Ash.UUID.generate()

      # Create a post
      post = create_post!(%{title: "9AM Post", status: :draft, author_id: actor_id})

      # Actor with business_hours_injectable scope
      actor = custom_perms_actor(["post:*:read:business_hours_injectable"], actor_id)

      # Pass a timestamp at start of business hours (9:00 AM)
      start_time = ~N[2024-01-15 09:00:00]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: start_time})
        |> Ash.read!(actor: actor)

      # Should see the post (9 is included in BETWEEN 9 AND 17)
      assert length(posts) == 1
      assert hd(posts).id == post.id
    end

    test "business_hours_injectable scope boundary test at hour 8 (excluded)" do
      actor_id = Ash.UUID.generate()

      # Create a post
      _post = create_post!(%{title: "8AM Post", status: :draft, author_id: actor_id})

      # Actor with business_hours_injectable scope
      actor = custom_perms_actor(["post:*:read:business_hours_injectable"], actor_id)

      # Pass a timestamp just before business hours (8:59 AM -> hour 8)
      before_start = ~N[2024-01-15 08:59:00]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: before_start})
        |> Ash.read!(actor: actor)

      # Should NOT see any posts (8 is not between 9 and 17)
      assert length(posts) == 0
    end
  end

  describe "scope :business_hours_local - timezone-aware filtering with AT TIME ZONE" do
    @moduledoc """
    Tests for timezone-aware business hours filtering.

    This demonstrates a common real-world pattern where:
    - Times are stored in UTC in the database
    - Business hours need to be evaluated in the user's local timezone
    - The timezone can come from context (request) or actor (user profile)

    Example scenarios:
    - A user in Asia/Seoul (UTC+9) should see posts during 9-17 KST
    - A user in America/New_York (UTC-5) should see posts during 9-17 EST
    """

    test "business_hours_local allows access during business hours in Asia/Seoul timezone" do
      actor_id = Ash.UUID.generate()
      post = create_post!(%{title: "Seoul Post", status: :draft, author_id: actor_id})

      actor = custom_perms_actor(["post:*:read:business_hours_local"], actor_id)

      # UTC time: 01:00 (1 AM UTC)
      # In Asia/Seoul (UTC+9): 10:00 (10 AM) - WITHIN business hours
      utc_time = ~U[2024-01-15 01:00:00Z]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time, timezone: "Asia/Seoul"})
        |> Ash.read!(actor: actor)

      # Should see the post (10 AM in Seoul is within 9-17)
      assert length(posts) == 1
      assert hd(posts).id == post.id
    end

    test "business_hours_local denies access outside business hours in Asia/Seoul timezone" do
      actor_id = Ash.UUID.generate()
      _post = create_post!(%{title: "Seoul Night Post", status: :draft, author_id: actor_id})

      actor = custom_perms_actor(["post:*:read:business_hours_local"], actor_id)

      # UTC time: 12:00 (noon UTC)
      # In Asia/Seoul (UTC+9): 21:00 (9 PM) - OUTSIDE business hours
      utc_time = ~U[2024-01-15 12:00:00Z]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time, timezone: "Asia/Seoul"})
        |> Ash.read!(actor: actor)

      # Should NOT see any posts (9 PM in Seoul is outside 9-17)
      assert length(posts) == 0
    end

    test "business_hours_local allows access during business hours in America/New_York timezone" do
      actor_id = Ash.UUID.generate()
      post = create_post!(%{title: "NYC Post", status: :draft, author_id: actor_id})

      actor = custom_perms_actor(["post:*:read:business_hours_local"], actor_id)

      # UTC time: 15:00 (3 PM UTC)
      # In America/New_York (UTC-5 in winter): 10:00 (10 AM) - WITHIN business hours
      utc_time = ~U[2024-01-15 15:00:00Z]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time, timezone: "America/New_York"})
        |> Ash.read!(actor: actor)

      # Should see the post (10 AM in NYC is within 9-17)
      assert length(posts) == 1
      assert hd(posts).id == post.id
    end

    test "business_hours_local denies access outside business hours in America/New_York timezone" do
      actor_id = Ash.UUID.generate()
      _post = create_post!(%{title: "NYC Night Post", status: :draft, author_id: actor_id})

      actor = custom_perms_actor(["post:*:read:business_hours_local"], actor_id)

      # UTC time: 03:00 (3 AM UTC)
      # In America/New_York (UTC-5 in winter): 22:00 (10 PM) - OUTSIDE business hours
      utc_time = ~U[2024-01-15 03:00:00Z]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time, timezone: "America/New_York"})
        |> Ash.read!(actor: actor)

      # Should NOT see any posts (10 PM in NYC is outside 9-17)
      assert length(posts) == 0
    end

    test "same UTC time yields different results for different timezones" do
      actor_id = Ash.UUID.generate()
      post = create_post!(%{title: "Global Post", status: :draft, author_id: actor_id})

      actor = custom_perms_actor(["post:*:read:business_hours_local"], actor_id)

      # UTC time: 00:00 (midnight UTC)
      # In Asia/Seoul (UTC+9): 09:00 (9 AM) - START of business hours
      # In America/New_York (UTC-5): 19:00 (7 PM) - OUTSIDE business hours
      utc_time = ~U[2024-01-15 00:00:00Z]

      # Seoul user - should see the post
      seoul_posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time, timezone: "Asia/Seoul"})
        |> Ash.read!(actor: actor)

      assert length(seoul_posts) == 1
      assert hd(seoul_posts).id == post.id

      # NYC user - should NOT see the post
      nyc_posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time, timezone: "America/New_York"})
        |> Ash.read!(actor: actor)

      assert length(nyc_posts) == 0
    end
  end

  describe "scope :business_hours_actor_tz - actor's timezone from profile" do
    test "uses actor's timezone for business hours check" do
      actor_id = Ash.UUID.generate()
      post = create_post!(%{title: "Actor TZ Post", status: :draft, author_id: actor_id})

      # Actor has timezone stored in their profile
      actor = %{
        id: actor_id,
        permissions: ["post:*:read:business_hours_actor_tz"],
        timezone: "Asia/Seoul"
      }

      # UTC time: 01:00 (1 AM UTC)
      # In Asia/Seoul (UTC+9): 10:00 (10 AM) - WITHIN business hours
      utc_time = ~U[2024-01-15 01:00:00Z]

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time})
        |> Ash.read!(actor: actor)

      # Should see the post (actor's timezone is Seoul, 10 AM is within 9-17)
      assert length(posts) == 1
      assert hd(posts).id == post.id
    end

    test "different actors with different timezones see different results" do
      author_id = Ash.UUID.generate()
      post = create_post!(%{title: "Multi-TZ Post", status: :draft, author_id: author_id})

      # UTC time: 00:00 (midnight UTC)
      # In Asia/Seoul (UTC+9): 09:00 (9 AM) - START of business hours
      # In America/New_York (UTC-5): 19:00 (7 PM) - OUTSIDE business hours
      utc_time = ~U[2024-01-15 00:00:00Z]

      # Seoul user
      seoul_actor = %{
        id: Ash.UUID.generate(),
        permissions: ["post:*:read:business_hours_actor_tz"],
        timezone: "Asia/Seoul"
      }

      seoul_posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time})
        |> Ash.read!(actor: seoul_actor)

      assert length(seoul_posts) == 1
      assert hd(seoul_posts).id == post.id

      # NYC user
      nyc_actor = %{
        id: Ash.UUID.generate(),
        permissions: ["post:*:read:business_hours_actor_tz"],
        timezone: "America/New_York"
      }

      nyc_posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.set_context(%{current_time: utc_time})
        |> Ash.read!(actor: nyc_actor)

      assert length(nyc_posts) == 0
    end
  end
end

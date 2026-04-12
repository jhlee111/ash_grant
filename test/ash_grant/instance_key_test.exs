defmodule AshGrant.InstanceKeyTest do
  @moduledoc """
  Tests for the instance_key feature (#63).

  User Story: As a developer, I want to match instance permissions against
  a custom field (e.g., feed_id) so I can use non-PK external identifiers
  in permission strings.
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Test.Feed

  # Helper to create a feed in the DB
  defp create_feed!(opts) do
    generate(feed(opts))
  end

  # Helper to read feeds with actor
  defp read_feeds(actor) do
    Feed
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: actor)
  end

  describe "instance_key :feed_id — read filtering" do
    test "instance permission matches against feed_id, not id" do
      feed1 = create_feed!(feed_id: "feed_aaa", title: "Feed A")
      _feed2 = create_feed!(feed_id: "feed_bbb", title: "Feed B")

      actor = %{id: Ash.UUID.generate(), permissions: ["feed:feed_aaa:read:"]}

      feeds = read_feeds(actor)
      assert length(feeds) == 1
      assert hd(feeds).feed_id == "feed_aaa"
      assert hd(feeds).id == feed1.id
    end

    test "multiple instance permissions match correctly" do
      _feed1 = create_feed!(feed_id: "feed_aaa", title: "Feed A")
      _feed2 = create_feed!(feed_id: "feed_bbb", title: "Feed B")
      _feed3 = create_feed!(feed_id: "feed_ccc", title: "Feed C")

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["feed:feed_aaa:read:", "feed:feed_ccc:read:"]
      }

      feeds = read_feeds(actor)
      assert length(feeds) == 2
      feed_ids = Enum.map(feeds, & &1.feed_id)
      assert "feed_aaa" in feed_ids
      assert "feed_ccc" in feed_ids
    end

    test "RBAC scope:always still works alongside instance_key" do
      _feed1 = create_feed!(feed_id: "feed_aaa", status: :published)
      _feed2 = create_feed!(feed_id: "feed_bbb", status: :draft)

      actor = %{id: Ash.UUID.generate(), permissions: ["feed:*:read:always"]}

      feeds = read_feeds(actor)
      assert length(feeds) == 2
    end

    test "combined RBAC + instance permissions (OR logic)" do
      _feed1 = create_feed!(feed_id: "feed_aaa", status: :published)
      _feed2 = create_feed!(feed_id: "feed_bbb", status: :draft)
      _feed3 = create_feed!(feed_id: "feed_ccc", status: :draft)

      # published scope + instance permission for feed_ccc
      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["feed:*:read:published", "feed:feed_ccc:read:"]
      }

      feeds = read_feeds(actor)
      assert length(feeds) == 2
      feed_ids = Enum.map(feeds, & &1.feed_id)
      assert "feed_aaa" in feed_ids
      assert "feed_ccc" in feed_ids
    end

    test "deny instance permission blocks access" do
      _feed1 = create_feed!(feed_id: "feed_aaa")

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["feed:feed_aaa:read:", "!feed:feed_aaa:read:"]
      }

      result = Feed |> Ash.Query.for_read(:read) |> Ash.read(actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "no permissions returns forbidden" do
      _feed1 = create_feed!(feed_id: "feed_aaa")

      actor = %{id: Ash.UUID.generate(), permissions: []}

      result = Feed |> Ash.Query.for_read(:read) |> Ash.read(actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "instance_key :feed_id — CanPerform calculation" do
    test "can_update? uses feed_id for instance matching" do
      _feed1 = create_feed!(feed_id: "feed_aaa", title: "Feed A")
      _feed2 = create_feed!(feed_id: "feed_bbb", title: "Feed B")

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["feed:*:read:always", "feed:feed_aaa:update:"]
      }

      feeds =
        Feed
        |> Ash.Query.for_read(:read)
        |> Ash.Query.load([:can_update?])
        |> Ash.read!(actor: actor)

      feeds_by_feed_id = Map.new(feeds, &{&1.feed_id, &1})
      assert feeds_by_feed_id["feed_aaa"].can_update? == true
      assert feeds_by_feed_id["feed_bbb"].can_update? == false
    end

    test "can_update? with RBAC scope shows true for matching records" do
      _feed1 = create_feed!(feed_id: "feed_aaa", status: :published)
      _feed2 = create_feed!(feed_id: "feed_bbb", status: :draft)

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["feed:*:read:always", "feed:*:update:published"]
      }

      feeds =
        Feed
        |> Ash.Query.for_read(:read)
        |> Ash.Query.load([:can_update?])
        |> Ash.read!(actor: actor)

      feeds_by_feed_id = Map.new(feeds, &{&1.feed_id, &1})
      assert feeds_by_feed_id["feed_aaa"].can_update? == true
      assert feeds_by_feed_id["feed_bbb"].can_update? == false
    end
  end
end

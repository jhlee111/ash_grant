defmodule AshGrant.ContextInjectionTest do
  @moduledoc """
  Tests for context injection in scope expressions.

  This enables testable temporal and parameterized scopes by allowing
  values to be injected via Ash's query/changeset context rather than
  relying on database functions like CURRENT_DATE.

  Use cases:
  - Temporal scopes with injectable dates: `scope :today, expr(date == ^context(:reference_date))`
  - Parameterized thresholds: `scope :low_value, expr(amount < ^context(:threshold))`
  - Environment-specific filtering: `scope :region, expr(region == ^context(:region))`
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.Post

  # === Test Actors ===

  defp actor_with_perms(perms, id \\ Ash.UUID.generate()) do
    %{id: id, permissions: perms}
  end

  # === Helper Functions ===

  defp create_post!(attrs) do
    Post
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp read_posts_with_context(actor, context) do
    Post
    |> Ash.Query.for_read(:read)
    |> Ash.Query.set_context(context)
    |> Ash.read!(actor: actor)
  end

  # === Tests ===

  describe "context injection in temporal scopes" do
    test "today scope with injected reference_date matches records from that date" do
      actor_id = Ash.UUID.generate()

      # Create a post
      post = create_post!(%{title: "Test Post", status: :draft, author_id: actor_id})

      # Get the actual inserted_at date
      post_date = DateTime.to_date(post.inserted_at)

      # Actor with today scope permission
      actor = actor_with_perms(["post:*:read:today_injectable"], actor_id)

      # Pass the reference date via context - should match
      posts = read_posts_with_context(actor, %{reference_date: post_date})

      assert length(posts) == 1
      assert hd(posts).id == post.id
    end

    test "today scope with different reference_date excludes records" do
      actor_id = Ash.UUID.generate()

      # Create a post
      _post = create_post!(%{title: "Test Post", status: :draft, author_id: actor_id})

      # Actor with today scope permission
      actor = actor_with_perms(["post:*:read:today_injectable"], actor_id)

      # Pass a different date - should NOT match
      yesterday = Date.add(Date.utc_today(), -1)
      posts = read_posts_with_context(actor, %{reference_date: yesterday})

      assert length(posts) == 0
    end
  end

  describe "context injection in parameterized scopes" do
    test "threshold scope respects injected value" do
      actor_id = Ash.UUID.generate()

      # Create posts (using title length as a proxy for "amount" since Post doesn't have amount)
      short_post = create_post!(%{title: "Hi", status: :draft, author_id: actor_id})

      _long_post =
        create_post!(%{title: "This is a very long title", status: :draft, author_id: actor_id})

      # Actor with threshold scope permission
      actor = actor_with_perms(["post:*:read:short_title"], actor_id)

      # Inject threshold of 10 characters
      posts = read_posts_with_context(actor, %{max_title_length: 10})

      assert length(posts) == 1
      assert hd(posts).id == short_post.id
    end
  end
end

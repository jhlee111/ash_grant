defmodule AshGrant.DefaultPoliciesTest do
  @moduledoc """
  Tests for the default_policies feature (v0.2.0).

  This module tests the automatic policy generation when `default_policies: true`
  is set in the ash_grant DSL configuration.

  ## Test Coverage

  - Auto-generated read policy with `filter_check/1`
  - Auto-generated write policy with `check/1`
  - Scope-based filtering (`:own`, `:published`, `:all`)
  - Role-based permissions (admin, editor, viewer)
  - Proper `Ash.Expr.eval/2` integration for actor references

  ## Test Resource

  Uses `AshGrant.Test.Article` which demonstrates:
  - `default_policies: true` configuration
  - Inline scope DSL with `expr()` expressions
  - Role-based permission resolution via anonymous function
  """

  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Test.Article

  describe "default_policies: true" do
    test "auto-generates read policy with filter_check" do
      # Create articles
      published = generate(published_article())
      _draft = generate(draft_article())

      # Viewer can only see published
      actor = %{role: :viewer}
      articles = Article |> Ash.read!(actor: actor)
      ids = Enum.map(articles, & &1.id)

      assert length(articles) == 1
      assert published.id in ids
    end

    test "auto-generates write policy with check" do
      actor_id = Ash.UUID.generate()
      actor = %{role: :editor, id: actor_id}

      # Editor can create articles
      {:ok, article} = Ash.create(Article, %{title: "Test", author_id: actor_id}, actor: actor)
      assert article.title == "Test"
    end

    test "editor can read all articles" do
      published = generate(published_article())
      draft = generate(draft_article())

      actor = %{role: :editor}
      articles = Article |> Ash.read!(actor: actor)
      ids = Enum.map(articles, & &1.id)

      assert length(articles) == 2
      assert published.id in ids
      assert draft.id in ids
    end

    test "editor can only update own articles" do
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      my_article = generate(article(author_id: actor_id))
      other_article = generate(article(author_id: other_id))

      actor = %{role: :editor, id: actor_id}

      # Can update own article
      {:ok, updated} = Ash.update(my_article, %{title: "Updated"}, actor: actor)
      assert updated.title == "Updated"

      # Cannot update other's article
      assert {:error, %Ash.Error.Forbidden{}} =
        Ash.update(other_article, %{title: "Hacked"}, actor: actor)
    end

    test "admin can do everything" do
      draft = generate(draft_article())

      actor = %{role: :admin}

      # Admin can read
      articles = Article |> Ash.read!(actor: actor)
      assert length(articles) >= 1
      assert draft.id in Enum.map(articles, & &1.id)

      # Admin can update
      {:ok, updated} = Ash.update(draft, %{title: "Admin Updated"}, actor: actor)
      assert updated.title == "Admin Updated"

      # Admin can destroy
      :ok = Ash.destroy(updated, actor: actor)
    end

    test "nil actor raises Forbidden" do
      _article = generate(article())

      assert_raise Ash.Error.Forbidden, fn ->
        Article |> Ash.read!(actor: nil)
      end
    end

    test "actor with no permissions raises Forbidden" do
      _article = generate(article())

      actor = %{role: :unknown}

      assert_raise Ash.Error.Forbidden, fn ->
        Article |> Ash.read!(actor: actor)
      end
    end
  end

  describe "AshGrant.Info.default_policies/1" do
    test "returns the configured value" do
      assert AshGrant.Info.default_policies(Article) == true
    end
  end
end

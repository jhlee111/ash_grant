defmodule AshGrant.ScopeDslTest do
  use ExUnit.Case, async: true

  alias AshGrant.Info

  # Test resource with scope DSL
  # Note: expr macro is auto-imported by the ash_grant DSL section
  defmodule TestPost do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(fn _actor, _context -> [] end)

      scope(:all, [], true, description: "All records without restriction")

      scope(:published, [], expr(status == :published),
        description: "Published posts visible to everyone"
      )

      scope(:draft, expr(status == :draft))
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:status, :atom, constraints: [one_of: [:draft, :published]])
      attribute(:author_id, :uuid)
    end
  end

  # Test resource with inherited scope
  defmodule TestComment do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(fn _actor, _context -> [] end)

      scope(:all, true)
      scope(:pending, expr(status == :pending))
      scope(:all_pending, [:all], expr(status == :pending))
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:body, :string, public?: true)
      attribute(:status, :atom, constraints: [one_of: [:pending, :approved]])
      attribute(:author_id, :uuid)
    end
  end

  describe "scope DSL definition" do
    test "defines scopes on resource" do
      scopes = Info.scopes(TestPost)
      assert length(scopes) == 3

      scope_names = Enum.map(scopes, & &1.name)
      assert :all in scope_names
      assert :published in scope_names
      assert :draft in scope_names
    end

    test "scope has name and filter" do
      scopes = Info.scopes(TestPost)
      all_scope = Enum.find(scopes, &(&1.name == :all))

      assert all_scope.name == :all
      assert all_scope.filter == true
      # inherits can be nil or empty list when not specified
      assert all_scope.inherits in [nil, []]
    end

    test "scope can have expression filter" do
      scopes = Info.scopes(TestPost)
      published_scope = Enum.find(scopes, &(&1.name == :published))

      assert published_scope.name == :published
      assert published_scope.filter != nil
      refute published_scope.filter == true
    end
  end

  describe "scope inheritance" do
    test "scope can inherit from another scope" do
      scopes = Info.scopes(TestComment)
      all_pending_scope = Enum.find(scopes, &(&1.name == :all_pending))

      assert all_pending_scope.name == :all_pending
      assert all_pending_scope.inherits == [:all]
    end
  end

  describe "Info.get_scope/2" do
    test "returns scope by name" do
      scope = Info.get_scope(TestPost, :published)
      assert scope.name == :published
    end

    test "returns nil for unknown scope" do
      assert Info.get_scope(TestPost, :unknown) == nil
    end
  end

  describe "Info.resolve_scope_filter/3" do
    test "returns true for :all scope" do
      filter = Info.resolve_scope_filter(TestPost, :all, %{})
      assert filter == true
    end

    test "returns expression for :published scope" do
      filter = Info.resolve_scope_filter(TestPost, :published, %{})
      # Should return an Ash expression
      assert filter != nil
      refute filter == true
    end

    test "returns false for unknown scope" do
      filter = Info.resolve_scope_filter(TestPost, :unknown, %{})
      assert filter == false
    end

    test "combines inherited scope with own filter" do
      filter = Info.resolve_scope_filter(TestComment, :all_pending, %{})
      # :all is true, so result should just be the pending filter
      assert filter != nil
      refute filter == true
    end
  end

  describe "scope description" do
    test "scope can have description" do
      scope = Info.get_scope(TestPost, :all)
      assert scope.description == "All records without restriction"
    end

    test "scope description is optional" do
      scope = Info.get_scope(TestPost, :draft)
      assert scope.description == nil
    end

    test "Info.scope_description/2 returns description for existing scope" do
      assert Info.scope_description(TestPost, :all) == "All records without restriction"
      assert Info.scope_description(TestPost, :published) == "Published posts visible to everyone"
    end

    test "Info.scope_description/2 returns nil for scope without description" do
      assert Info.scope_description(TestPost, :draft) == nil
    end

    test "Info.scope_description/2 returns nil for unknown scope" do
      assert Info.scope_description(TestPost, :unknown) == nil
    end
  end
end

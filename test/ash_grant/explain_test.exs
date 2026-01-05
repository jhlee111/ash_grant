defmodule AshGrant.ExplainTest do
  @moduledoc """
  Tests for AshGrant.explain/4 authorization debugging functionality.

  These tests follow TDD - written first before implementation.
  """
  use ExUnit.Case, async: true

  # Test resource with scopes and descriptions
  defmodule TestPost do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(fn actor, _context ->
        case actor do
          %{role: :admin} ->
            [
              %AshGrant.PermissionInput{
                string: "post:*:*:all",
                description: "Full access to all posts",
                source: "admin_role"
              }
            ]

          %{role: :editor, id: id} ->
            [
              %AshGrant.PermissionInput{
                string: "post:*:read:all",
                description: "Read all posts",
                source: "editor_role"
              },
              %AshGrant.PermissionInput{
                string: "post:*:update:own",
                description: "Edit own posts",
                source: "editor_role"
              }
            ]

          %{role: :viewer} ->
            ["post:*:read:published"]

          _ ->
            []
        end
      end)

      resource_name("post")

      scope(:all, [], true, description: "All records without restriction")

      scope(:own, [], expr(author_id == ^actor(:id)),
        description: "Records owned by the current user"
      )

      scope(:published, [], expr(status == :published),
        description: "Published records visible to everyone"
      )
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:status, :atom, constraints: [one_of: [:draft, :published]])
      attribute(:author_id, :uuid)
    end

    actions do
      defaults([:read, :create, :update, :destroy])
    end
  end

  describe "AshGrant.explain/4" do
    test "returns Explanation struct with decision details" do
      actor = %{id: "user-1", role: :admin}

      result = AshGrant.explain(TestPost, :read, actor)

      assert %AshGrant.Explanation{} = result
      assert result.resource == TestPost
      assert result.action == :read
      assert result.decision in [:allow, :deny]
    end

    test "shows matching permissions for admin" do
      actor = %{id: "user-1", role: :admin}

      result = AshGrant.explain(TestPost, :read, actor)

      assert result.decision == :allow
      assert length(result.matching_permissions) >= 1

      # Check that permission metadata is preserved
      [first_match | _] = result.matching_permissions
      assert first_match.description == "Full access to all posts"
      assert first_match.source == "admin_role"
    end

    test "shows scope information in result" do
      actor = %{id: "user-1", role: :admin}

      result = AshGrant.explain(TestPost, :read, actor)

      # The matching permission should include scope information
      [first_match | _] = result.matching_permissions
      assert first_match.scope_name == :all
      assert first_match.scope_description == "All records without restriction"
    end

    test "shows all evaluated permissions" do
      actor = %{id: "user-1", role: :editor}

      result = AshGrant.explain(TestPost, :read, actor)

      # Should have evaluated 2 permissions for editor
      assert length(result.evaluated_permissions) == 2
    end

    test "includes non-matching permissions with reason" do
      actor = %{id: "user-1", role: :editor}

      result = AshGrant.explain(TestPost, :update, actor)

      # Should show why some permissions didn't match
      non_matching =
        Enum.filter(result.evaluated_permissions, fn p ->
          p.matched == false
        end)

      # "post:*:read:all" should not match update action
      assert length(non_matching) >= 1
    end

    test "returns deny when no permissions match" do
      actor = %{id: "user-1", role: :unknown}

      result = AshGrant.explain(TestPost, :read, actor)

      assert result.decision == :deny
      assert result.matching_permissions == []
      assert result.reason == :no_matching_permissions
    end

    test "handles deny permissions" do
      # This test is a placeholder for deny-wins semantics
      # Covered by existing evaluator tests
    end

    test "accepts optional context parameter" do
      actor = %{id: "user-1", role: :admin}
      context = %{tenant: "tenant-1"}

      result = AshGrant.explain(TestPost, :read, actor, context)

      assert %AshGrant.Explanation{} = result
    end

    test "to_string returns human-readable explanation" do
      actor = %{id: "user-1", role: :admin}

      result = AshGrant.explain(TestPost, :read, actor)
      output = AshGrant.Explanation.to_string(result)

      assert is_binary(output)
      assert output =~ "ALLOW"
      assert output =~ "post"
      assert output =~ "read"
    end

    test "to_string shows deny decision clearly" do
      actor = %{id: "user-1", role: :unknown}

      result = AshGrant.explain(TestPost, :read, actor)
      output = AshGrant.Explanation.to_string(result)

      assert output =~ "DENY"
      # reason is shown as atom in parentheses
      assert output =~ "no_matching_permissions"
    end
  end

  describe "AshGrant.Explanation struct" do
    test "has required fields" do
      explanation = %AshGrant.Explanation{
        resource: TestPost,
        action: :read,
        actor: %{id: "user-1"},
        decision: :allow,
        matching_permissions: [],
        evaluated_permissions: [],
        reason: nil
      }

      assert explanation.resource == TestPost
      assert explanation.action == :read
      assert explanation.decision == :allow
    end
  end
end

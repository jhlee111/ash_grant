defmodule AshGrant.EvaluatorTest do
  use ExUnit.Case, async: true

  alias AshGrant.Evaluator

  describe "has_access?/3 - new format" do
    test "grants access with matching permission" do
      permissions = ["blog:*:read:always"]
      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "denies access without matching permission" do
      permissions = ["blog:*:read:always"]
      refute Evaluator.has_access?(permissions, "blog", "write")
    end

    test "grants access with wildcard action" do
      permissions = ["blog:*:*:always"]
      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.has_access?(permissions, "blog", "write")
      assert Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "action type wildcard requires action_type" do
      permissions = ["blog:*:read*:always"]
      # read* requires action_type — 3-arg call never matches
      refute Evaluator.has_access?(permissions, "blog", "read")
      refute Evaluator.has_access?(permissions, "blog", "read_all")
      refute Evaluator.has_access?(permissions, "blog", "write")
      # With action_type, matches
      assert Evaluator.has_access?(permissions, "blog", "read", :read)
      assert Evaluator.has_access?(permissions, "blog", "list", :read)
    end

    test "deny wins over allow" do
      permissions = [
        "blog:*:*:always",
        "!blog:*:delete:always"
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.has_access?(permissions, "blog", "write")
      refute Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "deny wins regardless of order" do
      permissions = [
        "!blog:*:delete:always",
        "blog:*:*:always"
      ]

      refute Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "multiple permissions" do
      permissions = [
        "blog:*:read:always",
        "blog:*:write:own",
        "comment:*:read:always"
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.has_access?(permissions, "blog", "write")
      assert Evaluator.has_access?(permissions, "comment", "read")
      refute Evaluator.has_access?(permissions, "comment", "write")
    end

    test "empty permissions denies all" do
      permissions = []
      refute Evaluator.has_access?(permissions, "blog", "read")
    end

    test "works with Permission structs" do
      permissions = [
        AshGrant.Permission.parse!("blog:*:read:always")
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "works with maps" do
      permissions = [
        %{resource: "blog", instance_id: "*", action: "read", scope: "always", deny: false}
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
    end
  end

  describe "has_access?/3 - legacy format compatibility" do
    test "grants access with legacy three-part format" do
      permissions = ["blog:read:always"]
      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "grants access with legacy two-part format" do
      permissions = ["blog:read"]
      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "deny wins with legacy format" do
      permissions = [
        "blog:*:always",
        "!blog:delete:always"
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      refute Evaluator.has_access?(permissions, "blog", "delete")
    end
  end

  describe "has_instance_access?/3" do
    test "grants access to specific instance" do
      permissions = ["blog:post_abc123xyz789ab:read:"]
      assert Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "read")
    end

    test "denies access to different instance" do
      permissions = ["blog:post_abc123xyz789ab:read:"]
      refute Evaluator.has_instance_access?(permissions, "post_xyz789abc123xy", "read")
    end

    test "grants access with wildcard action" do
      permissions = ["blog:post_abc123xyz789ab:*:"]
      assert Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "read")
      assert Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "write")
    end

    test "deny wins for instance permissions" do
      permissions = [
        "blog:post_abc123xyz789ab:*:",
        "!blog:post_abc123xyz789ab:delete:"
      ]

      assert Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "read")
      refute Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "delete")
    end

    test "RBAC permission does not grant instance access" do
      permissions = ["blog:*:read:always"]
      refute Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "read")
    end
  end

  describe "get_scope/3" do
    test "returns scope from matching permission" do
      permissions = ["blog:*:read:always"]
      assert Evaluator.get_scope(permissions, "blog", "read") == "always"
    end

    test "returns nil for no match" do
      permissions = ["blog:*:read:always"]
      assert Evaluator.get_scope(permissions, "blog", "write") == nil
    end

    test "returns nil when denied" do
      permissions = [
        "blog:*:*:always",
        "!blog:*:delete:always"
      ]

      assert Evaluator.get_scope(permissions, "blog", "read") == "always"
      assert Evaluator.get_scope(permissions, "blog", "delete") == nil
    end

    test "returns first matching scope" do
      permissions = [
        "blog:*:read:own",
        "blog:*:read:published"
      ]

      assert Evaluator.get_scope(permissions, "blog", "read") == "own"
    end

    test "works with legacy format" do
      permissions = ["blog:read:always"]
      assert Evaluator.get_scope(permissions, "blog", "read") == "always"
    end
  end

  describe "get_all_scopes/3" do
    test "returns all matching scopes" do
      permissions = [
        "blog:*:read:own",
        "blog:*:read:published",
        "blog:*:read:always"
      ]

      scopes = Evaluator.get_all_scopes(permissions, "blog", "read")
      assert "own" in scopes
      assert "published" in scopes
      assert "always" in scopes
    end

    test "returns empty list when denied" do
      permissions = [
        "blog:*:*:always",
        "!blog:*:delete:always"
      ]

      assert Evaluator.get_all_scopes(permissions, "blog", "delete") == []
    end

    test "returns empty list for no match" do
      permissions = ["blog:*:read:always"]
      assert Evaluator.get_all_scopes(permissions, "blog", "write") == []
    end

    test "returns unique scopes" do
      permissions = [
        "blog:*:read:always",
        "blog:*:*:always"
      ]

      scopes = Evaluator.get_all_scopes(permissions, "blog", "read")
      assert scopes == ["always"]
    end
  end

  describe "find_matching/3" do
    test "finds all matching permissions" do
      permissions = [
        "blog:*:read:always",
        "blog:*:*:own",
        "!blog:*:delete:always",
        "comment:*:read:always"
      ]

      matching = Evaluator.find_matching(permissions, "blog", "read")
      assert length(matching) == 2
    end

    test "finds deny permissions too" do
      permissions = [
        "blog:*:*:always",
        "!blog:*:delete:always"
      ]

      matching = Evaluator.find_matching(permissions, "blog", "delete")
      assert length(matching) == 2
    end
  end

  describe "field group evaluation" do
    test "get_field_group returns field group from matching permission" do
      permissions = ["employee:*:read:always:sensitive"]
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
    end

    test "get_field_group returns nil when no field_group in permission" do
      permissions = ["employee:*:read:always"]
      assert Evaluator.get_field_group(permissions, "employee", "read") == nil
    end

    test "get_field_group returns nil when denied" do
      permissions = ["employee:*:read:always:sensitive", "!employee:*:read:always"]
      assert Evaluator.get_field_group(permissions, "employee", "read") == nil
    end

    test "get_field_group returns nil when no matching permission" do
      permissions = ["employee:*:read:always:sensitive"]
      assert Evaluator.get_field_group(permissions, "employee", "write") == nil
    end

    test "get_all_field_groups returns all field groups from matching permissions" do
      permissions = ["employee:*:read:always:sensitive", "employee:*:read:always:billing"]

      assert Evaluator.get_all_field_groups(permissions, "employee", "read") == [
               "sensitive",
               "billing"
             ]
    end

    test "get_all_field_groups returns empty when denied" do
      permissions = ["employee:*:read:always:sensitive", "!employee:*:read:always"]
      assert Evaluator.get_all_field_groups(permissions, "employee", "read") == []
    end

    test "get_all_field_groups deduplicates" do
      permissions = [
        "employee:*:read:always:sensitive",
        "employee:*:read:own:sensitive"
      ]

      assert Evaluator.get_all_field_groups(permissions, "employee", "read") == ["sensitive"]
    end

    test "get_all_field_groups returns empty when no matching permissions" do
      permissions = ["employee:*:read:always:sensitive"]
      assert Evaluator.get_all_field_groups(permissions, "employee", "write") == []
    end

    test "get_all_field_groups ignores permissions without field_group" do
      permissions = [
        "employee:*:read:always:sensitive",
        "employee:*:read:own"
      ]

      assert Evaluator.get_all_field_groups(permissions, "employee", "read") == ["sensitive"]
    end
  end

  describe "5-part with deny field_group" do
    test "5-part deny blocks access even when field_group matches" do
      permissions = [
        "employee:*:read:always:sensitive",
        "!employee:*:read:always:sensitive"
      ]

      refute Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.get_field_group(permissions, "employee", "read") == nil
      assert Evaluator.get_all_field_groups(permissions, "employee", "read") == []
    end

    test "5-part deny on specific field_group blocks that field_group" do
      # Deny with field_group still matches resource:action, so deny-wins blocks everything
      permissions = [
        "employee:*:read:always:billing",
        "!employee:*:read:always:sensitive"
      ]

      # deny-wins: the deny matches resource+action, so all access is denied
      refute Evaluator.has_access?(permissions, "employee", "read")
    end

    test "5-part deny does not affect different resource" do
      permissions = [
        "employee:*:read:always:sensitive",
        "!blog:*:read:always:sensitive"
      ]

      assert Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
    end

    test "5-part deny does not affect different action" do
      permissions = [
        "employee:*:read:always:sensitive",
        "!employee:*:write:always:sensitive"
      ]

      assert Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
    end
  end

  describe "5-part with wildcards" do
    test "5-part with action wildcard grants access" do
      permissions = ["employee:*:*:always:sensitive"]
      assert Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.has_access?(permissions, "employee", "write")
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
    end

    test "5-part with action type wildcard grants access" do
      permissions = ["employee:*:read*:always:sensitive"]
      # read* requires action_type
      refute Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.has_access?(permissions, "employee", "read", :read)
      refute Evaluator.has_access?(permissions, "employee", "write")
      assert Evaluator.get_field_group(permissions, "employee", "read", :read) == "sensitive"
    end

    test "5-part with resource wildcard grants access" do
      permissions = ["*:*:read:always:sensitive"]
      assert Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
    end

    test "deny 5-part with action wildcard blocks specific actions" do
      permissions = [
        "employee:*:*:always:sensitive",
        "!employee:*:delete:always:sensitive"
      ]

      assert Evaluator.has_access?(permissions, "employee", "read")
      refute Evaluator.has_access?(permissions, "employee", "delete")
    end
  end

  describe "5-part instance permissions in evaluator" do
    test "5-part instance permission grants access" do
      permissions = ["employee:emp_123:read:draft:sensitive"]
      assert Evaluator.has_instance_access?(permissions, "emp_123", "read")
    end

    test "5-part instance permission denies different instance" do
      permissions = ["employee:emp_123:read:draft:sensitive"]
      refute Evaluator.has_instance_access?(permissions, "emp_456", "read")
    end

    test "5-part instance deny blocks instance access" do
      permissions = [
        "employee:emp_123:read::sensitive",
        "!employee:emp_123:read:"
      ]

      refute Evaluator.has_instance_access?(permissions, "emp_123", "read")
    end

    test "get_instance_scope works with 5-part" do
      permissions = ["employee:emp_123:read:draft:sensitive"]
      assert Evaluator.get_instance_scope(permissions, "emp_123", "read") == "draft"
    end

    test "get_instance_scope returns nil when 5-part instance is denied" do
      permissions = [
        "employee:emp_123:read:draft:sensitive",
        "!employee:emp_123:read:draft"
      ]

      assert Evaluator.get_instance_scope(permissions, "emp_123", "read") == nil
    end

    test "get_all_instance_scopes works with 5-part" do
      permissions = [
        "employee:emp_123:read:draft:sensitive",
        "employee:emp_123:read:pending:billing"
      ]

      scopes = Evaluator.get_all_instance_scopes(permissions, "emp_123", "read")
      assert "draft" in scopes
      assert "pending" in scopes
    end
  end

  describe "has_access?/4 with action_type" do
    test "read* matches :read type action with non-prefixed name" do
      permissions = ["blog:*:read*:always"]
      assert Evaluator.has_access?(permissions, "blog", "list_published", :read)
    end

    test "read* does NOT match :update type with non-prefixed name" do
      permissions = ["blog:*:read*:always"]
      refute Evaluator.has_access?(permissions, "blog", "list_published", :update)
    end

    test "deny-wins with action_type" do
      permissions = [
        "blog:*:read*:always",
        "!blog:*:read*:always"
      ]

      refute Evaluator.has_access?(permissions, "blog", "list_published", :read)
    end

    test "backward compat: 3-arg has_access? unchanged" do
      permissions = ["blog:*:read*:always"]
      # read* requires action_type — 3-arg call never matches
      refute Evaluator.has_access?(permissions, "blog", "read")
      refute Evaluator.has_access?(permissions, "blog", "read_all")
      refute Evaluator.has_access?(permissions, "blog", "list_published")
    end

    test "update* matches :update type for publish action" do
      permissions = ["blog:*:update*:own"]
      assert Evaluator.has_access?(permissions, "blog", "publish", :update)
      refute Evaluator.has_access?(permissions, "blog", "publish", :read)
    end
  end

  describe "get_scope/4 with action_type" do
    test "returns scope when read* matches via action_type" do
      permissions = ["blog:*:read*:published"]
      assert Evaluator.get_scope(permissions, "blog", "list_published", :read) == "published"
    end

    test "returns nil when action_type doesn't match" do
      permissions = ["blog:*:read*:always"]
      assert Evaluator.get_scope(permissions, "blog", "list_published", :update) == nil
    end

    test "returns nil when denied with action_type" do
      permissions = ["blog:*:read*:always", "!blog:*:read*:always"]
      assert Evaluator.get_scope(permissions, "blog", "by_slug", :read) == nil
    end
  end

  describe "get_all_scopes/4 with action_type" do
    test "returns all scopes matching via action_type" do
      permissions = [
        "blog:*:read*:own",
        "blog:*:read*:published"
      ]

      scopes = Evaluator.get_all_scopes(permissions, "blog", "search", :read)
      assert "own" in scopes
      assert "published" in scopes
    end

    test "returns empty when denied with action_type" do
      permissions = ["blog:*:read*:always", "!blog:*:read*:always"]
      assert Evaluator.get_all_scopes(permissions, "blog", "search", :read) == []
    end
  end

  describe "get_all_field_groups/4 with action_type" do
    test "returns field groups matching via action_type" do
      permissions = ["employee:*:read*:always:sensitive"]

      assert Evaluator.get_all_field_groups(permissions, "employee", "by_department", :read) == [
               "sensitive"
             ]
    end
  end

  describe "find_matching/4 with action_type" do
    test "finds permissions matching via action_type" do
      permissions = ["blog:*:read*:always", "blog:*:update*:own"]
      matching = Evaluator.find_matching(permissions, "blog", "search", :read)
      assert length(matching) == 1
    end
  end

  describe "get_matching_instance_ids/4 with action_type" do
    test "matches instance permissions via action_type" do
      permissions = ["blog:post_abc:read*:", "blog:post_xyz:read*:"]
      ids = Evaluator.get_matching_instance_ids(permissions, "blog", "by_slug", :read)
      assert "post_abc" in ids
      assert "post_xyz" in ids
    end
  end

  describe "combine/1" do
    test "combines multiple permission lists" do
      role_perms = ["blog:*:read:always"]
      instance_perms = ["blog:post_abc123xyz789ab:write:"]

      combined = Evaluator.combine([role_perms, instance_perms])

      assert Evaluator.has_access?(combined, "blog", "read")
      assert Evaluator.has_instance_access?(combined, "post_abc123xyz789ab", "write")
    end
  end
end

defmodule AshGrant.EvaluatorTest do
  use ExUnit.Case, async: true

  alias AshGrant.Evaluator

  describe "has_access?/3 - new format" do
    test "grants access with matching permission" do
      permissions = ["blog:*:read:all"]
      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "denies access without matching permission" do
      permissions = ["blog:*:read:all"]
      refute Evaluator.has_access?(permissions, "blog", "write")
    end

    test "grants access with wildcard action" do
      permissions = ["blog:*:*:all"]
      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.has_access?(permissions, "blog", "write")
      assert Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "grants access with action type wildcard" do
      permissions = ["blog:*:read*:all"]
      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.has_access?(permissions, "blog", "read_all")
      refute Evaluator.has_access?(permissions, "blog", "write")
    end

    test "deny wins over allow" do
      permissions = [
        "blog:*:*:all",
        "!blog:*:delete:all"
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.has_access?(permissions, "blog", "write")
      refute Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "deny wins regardless of order" do
      permissions = [
        "!blog:*:delete:all",
        "blog:*:*:all"
      ]

      refute Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "multiple permissions" do
      permissions = [
        "blog:*:read:all",
        "blog:*:write:own",
        "comment:*:read:all"
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
        AshGrant.Permission.parse!("blog:*:read:all")
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "works with maps" do
      permissions = [
        %{resource: "blog", instance_id: "*", action: "read", scope: "all", deny: false}
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
    end
  end

  describe "has_access?/3 - legacy format compatibility" do
    test "grants access with legacy three-part format" do
      permissions = ["blog:read:all"]
      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "grants access with legacy two-part format" do
      permissions = ["blog:read"]
      assert Evaluator.has_access?(permissions, "blog", "read")
    end

    test "deny wins with legacy format" do
      permissions = [
        "blog:*:all",
        "!blog:delete:all"
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
      permissions = ["blog:*:read:all"]
      refute Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "read")
    end
  end

  describe "get_scope/3" do
    test "returns scope from matching permission" do
      permissions = ["blog:*:read:all"]
      assert Evaluator.get_scope(permissions, "blog", "read") == "all"
    end

    test "returns nil for no match" do
      permissions = ["blog:*:read:all"]
      assert Evaluator.get_scope(permissions, "blog", "write") == nil
    end

    test "returns nil when denied" do
      permissions = [
        "blog:*:*:all",
        "!blog:*:delete:all"
      ]

      assert Evaluator.get_scope(permissions, "blog", "read") == "all"
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
      permissions = ["blog:read:all"]
      assert Evaluator.get_scope(permissions, "blog", "read") == "all"
    end
  end

  describe "get_all_scopes/3" do
    test "returns all matching scopes" do
      permissions = [
        "blog:*:read:own",
        "blog:*:read:published",
        "blog:*:read:all"
      ]

      scopes = Evaluator.get_all_scopes(permissions, "blog", "read")
      assert "own" in scopes
      assert "published" in scopes
      assert "all" in scopes
    end

    test "returns empty list when denied" do
      permissions = [
        "blog:*:*:all",
        "!blog:*:delete:all"
      ]

      assert Evaluator.get_all_scopes(permissions, "blog", "delete") == []
    end

    test "returns empty list for no match" do
      permissions = ["blog:*:read:all"]
      assert Evaluator.get_all_scopes(permissions, "blog", "write") == []
    end

    test "returns unique scopes" do
      permissions = [
        "blog:*:read:all",
        "blog:*:*:all"
      ]

      scopes = Evaluator.get_all_scopes(permissions, "blog", "read")
      assert scopes == ["all"]
    end
  end

  describe "find_matching/3" do
    test "finds all matching permissions" do
      permissions = [
        "blog:*:read:all",
        "blog:*:*:own",
        "!blog:*:delete:all",
        "comment:*:read:all"
      ]

      matching = Evaluator.find_matching(permissions, "blog", "read")
      assert length(matching) == 2
    end

    test "finds deny permissions too" do
      permissions = [
        "blog:*:*:all",
        "!blog:*:delete:all"
      ]

      matching = Evaluator.find_matching(permissions, "blog", "delete")
      assert length(matching) == 2
    end
  end

  describe "combine/1" do
    test "combines multiple permission lists" do
      role_perms = ["blog:*:read:all"]
      instance_perms = ["blog:post_abc123xyz789ab:write:"]

      combined = Evaluator.combine([role_perms, instance_perms])

      assert Evaluator.has_access?(combined, "blog", "read")
      assert Evaluator.has_instance_access?(combined, "post_abc123xyz789ab", "write")
    end
  end
end

defmodule AshGrant.PermissionTest do
  use ExUnit.Case, async: true

  alias AshGrant.Permission

  describe "parse/1 - new four-part format" do
    test "parses full RBAC permission" do
      assert {:ok, perm} = Permission.parse("blog:*:read:all")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == "all"
      assert perm.deny == false
    end

    test "parses deny permission" do
      assert {:ok, perm} = Permission.parse("!blog:*:delete:all")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "delete"
      assert perm.scope == "all"
      assert perm.deny == true
    end

    test "parses instance permission with empty scope" do
      assert {:ok, perm} = Permission.parse("blog:post_abc123xyz789ab:read:")
      assert perm.resource == "blog"
      assert perm.instance_id == "post_abc123xyz789ab"
      assert perm.action == "read"
      assert perm.scope == nil
      assert perm.deny == false
    end

    test "parses instance permission with wildcard action" do
      assert {:ok, perm} = Permission.parse("blog:post_abc123xyz789ab:*:")
      assert perm.resource == "blog"
      assert perm.instance_id == "post_abc123xyz789ab"
      assert perm.action == "*"
      assert perm.scope == nil
    end

    test "parses full wildcard permission" do
      assert {:ok, perm} = Permission.parse("*:*:*:all")
      assert perm.resource == "*"
      assert perm.instance_id == "*"
      assert perm.action == "*"
      assert perm.scope == "all"
    end

    test "parses action type wildcard" do
      assert {:ok, perm} = Permission.parse("blog:*:read*:all")
      assert perm.action == "read*"
    end
  end

  describe "parse/1 - legacy format compatibility" do
    test "parses legacy three-part format (resource:action:scope)" do
      assert {:ok, perm} = Permission.parse("blog:read:all")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == "all"
    end

    test "parses legacy two-part format (resource:action)" do
      assert {:ok, perm} = Permission.parse("blog:read")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == nil
    end

    test "parses legacy deny permission" do
      assert {:ok, perm} = Permission.parse("!blog:delete:all")
      assert perm.deny == true
      assert perm.instance_id == "*"
    end
  end

  describe "parse/1 - error handling" do
    test "returns error for single part" do
      assert {:error, _} = Permission.parse("invalid")
    end

    test "returns error for empty string" do
      assert {:error, _} = Permission.parse("")
    end
  end

  describe "parse!/1" do
    test "returns permission for valid string" do
      perm = Permission.parse!("blog:*:read:all")
      assert perm.resource == "blog"
    end

    test "raises for invalid string" do
      assert_raise ArgumentError, fn ->
        Permission.parse!("invalid")
      end
    end
  end

  describe "to_string/1" do
    test "converts RBAC permission to four-part format" do
      perm = %Permission{resource: "blog", instance_id: "*", action: "read", scope: "all"}
      assert Permission.to_string(perm) == "blog:*:read:all"
    end

    test "converts instance permission with empty scope" do
      perm = %Permission{resource: "blog", instance_id: "post_abc123", action: "read", scope: nil}
      assert Permission.to_string(perm) == "blog:post_abc123:read:"
    end

    test "converts deny permission" do
      perm = %Permission{resource: "blog", instance_id: "*", action: "delete", scope: "all", deny: true}
      assert Permission.to_string(perm) == "!blog:*:delete:all"
    end

    test "handles nil instance_id as *" do
      perm = %Permission{resource: "blog", instance_id: nil, action: "read", scope: "all"}
      assert Permission.to_string(perm) == "blog:*:read:all"
    end
  end

  describe "matches?/3 - RBAC matching" do
    test "matches exact resource and action" do
      perm = Permission.parse!("blog:*:read:all")
      assert Permission.matches?(perm, "blog", "read")
    end

    test "does not match different resource" do
      perm = Permission.parse!("blog:*:read:all")
      refute Permission.matches?(perm, "comment", "read")
    end

    test "does not match different action" do
      perm = Permission.parse!("blog:*:read:all")
      refute Permission.matches?(perm, "blog", "write")
    end

    test "matches wildcard resource" do
      perm = Permission.parse!("*:*:read:all")
      assert Permission.matches?(perm, "blog", "read")
      assert Permission.matches?(perm, "comment", "read")
    end

    test "matches wildcard action" do
      perm = Permission.parse!("blog:*:*:all")
      assert Permission.matches?(perm, "blog", "read")
      assert Permission.matches?(perm, "blog", "write")
      assert Permission.matches?(perm, "blog", "delete")
    end

    test "matches action type wildcard" do
      perm = Permission.parse!("blog:*:read*:all")
      assert Permission.matches?(perm, "blog", "read")
      assert Permission.matches?(perm, "blog", "read_all")
      assert Permission.matches?(perm, "blog", "read_published")
      refute Permission.matches?(perm, "blog", "write")
    end

    test "matches full wildcard" do
      perm = Permission.parse!("*:*:*:all")
      assert Permission.matches?(perm, "blog", "read")
      assert Permission.matches?(perm, "comment", "delete")
      assert Permission.matches?(perm, "anything", "any_action")
    end

    test "instance permission does not match RBAC query" do
      perm = Permission.parse!("blog:post_abc123xyz789ab:read:")
      refute Permission.matches?(perm, "blog", "read")
    end
  end

  describe "matches_instance?/3" do
    test "matches instance permission" do
      perm = Permission.parse!("blog:post_abc123xyz789ab:read:")
      assert Permission.matches_instance?(perm, "post_abc123xyz789ab", "read")
    end

    test "does not match different instance" do
      perm = Permission.parse!("blog:post_abc123xyz789ab:read:")
      refute Permission.matches_instance?(perm, "post_xyz789abc123xy", "read")
    end

    test "does not match different action" do
      perm = Permission.parse!("blog:post_abc123xyz789ab:read:")
      refute Permission.matches_instance?(perm, "post_abc123xyz789ab", "write")
    end

    test "matches instance wildcard action" do
      perm = Permission.parse!("blog:post_abc123xyz789ab:*:")
      assert Permission.matches_instance?(perm, "post_abc123xyz789ab", "read")
      assert Permission.matches_instance?(perm, "post_abc123xyz789ab", "write")
    end

    test "RBAC permission does not match instance query" do
      perm = Permission.parse!("blog:*:read:all")
      refute Permission.matches_instance?(perm, "post_abc123xyz789ab", "read")
    end
  end

  describe "instance_permission?/1" do
    test "returns true for instance permission" do
      perm = Permission.parse!("blog:post_abc123xyz789ab:read:")
      assert Permission.instance_permission?(perm)
    end

    test "returns false for RBAC permission" do
      perm = Permission.parse!("blog:*:read:all")
      refute Permission.instance_permission?(perm)
    end
  end

  describe "deny?/1" do
    test "returns true for deny permission" do
      perm = Permission.parse!("!blog:*:delete:all")
      assert Permission.deny?(perm)
    end

    test "returns false for allow permission" do
      perm = Permission.parse!("blog:*:read:all")
      refute Permission.deny?(perm)
    end
  end

  describe "String.Chars protocol" do
    test "converts to string" do
      perm = Permission.parse!("blog:*:read:all")
      assert "#{perm}" == "blog:*:read:all"
    end
  end
end

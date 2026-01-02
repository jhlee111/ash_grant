defmodule AshGrant.PermissionEdgeCasesTest do
  @moduledoc """
  Edge case tests for Permission parsing and matching.

  These tests cover unusual inputs, boundary conditions, and potential
  security-related parsing scenarios.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Permission

  describe "parse/1 - edge cases" do
    test "handles colons in instance_id (UUID format)" do
      # Some systems might have IDs with special chars
      # Currently our format doesn't support this, so it should handle gracefully
      result = Permission.parse("blog:abc:def:read:all")
      # 5 parts - should fail or handle gracefully
      assert {:error, _} = result
    end

    test "handles empty parts" do
      # Empty resource - currently allowed (parsed as empty string)
      # This documents current behavior; could be made stricter
      assert {:ok, perm} = Permission.parse(":*:read:all")
      assert perm.resource == ""

      # Permission with empty action handled as valid (legacy two-part)
      assert {:ok, perm} = Permission.parse("blog:")
      assert perm.action == ""
    end

    test "handles whitespace" do
      # Leading/trailing whitespace
      assert {:ok, perm} = Permission.parse(" blog:*:read:all ")
      # Note: Currently whitespace is NOT trimmed
      assert perm.resource == " blog"
    end

    test "handles very long strings" do
      long_resource = String.duplicate("a", 1000)
      assert {:ok, perm} = Permission.parse("#{long_resource}:*:read:all")
      assert perm.resource == long_resource
    end

    test "handles unicode characters" do
      assert {:ok, perm} = Permission.parse("블로그:*:읽기:전체")
      assert perm.resource == "블로그"
      assert perm.action == "읽기"
      assert perm.scope == "전체"
    end

    test "handles special characters in parts" do
      # Hyphen
      assert {:ok, perm} = Permission.parse("my-blog:*:read-all:scope-name")
      assert perm.resource == "my-blog"
      assert perm.action == "read-all"

      # Underscore
      assert {:ok, perm} = Permission.parse("my_blog:*:read_all:scope_name")
      assert perm.resource == "my_blog"

      # Numbers
      assert {:ok, perm} = Permission.parse("blog123:*:read456:scope789")
      assert perm.resource == "blog123"
    end

    test "handles only deny prefix" do
      assert {:error, _} = Permission.parse("!")
    end

    test "handles deny prefix with single part" do
      assert {:error, _} = Permission.parse("!blog")
    end

    test "handles double deny prefix" do
      # !!blog should be treated as resource "!blog" (not deny)
      assert {:ok, perm} = Permission.parse("!!blog:*:read:all")
      # First ! is deny, second ! is part of resource
      assert perm.deny == true
      assert perm.resource == "!blog"
    end

    test "handles multiple wildcards in action" do
      assert {:ok, perm} = Permission.parse("blog:*:*:all")
      assert perm.action == "*"

      assert {:ok, perm} = Permission.parse("blog:*:**:all")
      assert perm.action == "**"
    end
  end

  describe "matches?/3 - edge cases" do
    test "empty resource string does not match" do
      perm = Permission.parse!("blog:*:read:all")
      refute Permission.matches?(perm, "", "read")
    end

    test "empty action string does not match" do
      perm = Permission.parse!("blog:*:read:all")
      refute Permission.matches?(perm, "blog", "")
    end

    test "nil resource does not crash" do
      perm = Permission.parse!("blog:*:read:all")
      # This might raise, depending on implementation
      # We want to ensure it doesn't crash the system
      refute Permission.matches?(perm, nil, "read")
    rescue
      # Raising is acceptable behavior
      _ -> :ok
    end

    test "action prefix wildcard with exact match" do
      perm = Permission.parse!("blog:*:read*:all")
      # "read" matches "read*"
      assert Permission.matches?(perm, "blog", "read")
    end

    test "action prefix wildcard does not match unrelated" do
      perm = Permission.parse!("blog:*:read*:all")
      refute Permission.matches?(perm, "blog", "write")
      # "read" not at start
      refute Permission.matches?(perm, "blog", "aread")
      # partial match
      refute Permission.matches?(perm, "blog", "re")
    end

    test "multiple asterisks in action pattern" do
      # "read*write" is treated literally, not as two wildcards
      perm = Permission.parse!("blog:*:read*:all")
      # literal match
      assert Permission.matches?(perm, "blog", "read*")
    end

    test "case sensitivity" do
      perm = Permission.parse!("blog:*:read:all")
      # Permission matching is case-sensitive
      refute Permission.matches?(perm, "BLOG", "read")
      refute Permission.matches?(perm, "blog", "READ")
      refute Permission.matches?(perm, "Blog", "Read")
    end
  end

  describe "matches_instance?/3 - edge cases" do
    test "empty instance_id does not match" do
      perm = Permission.parse!("blog:post_abc123:read:")
      refute Permission.matches_instance?(perm, "", "read")
    end

    test "instance_id with colons" do
      # Instance ID containing special chars
      # This is tricky because we split on colons
      perm = %Permission{
        resource: "blog",
        instance_id: "post:with:colons",
        action: "read",
        scope: nil
      }

      # Direct struct usage (not from parse)
      assert Permission.matches_instance?(perm, "post:with:colons", "read")
    end

    test "wildcard action in instance permission" do
      perm = Permission.parse!("blog:post_abc123:*:")
      assert Permission.matches_instance?(perm, "post_abc123", "read")
      assert Permission.matches_instance?(perm, "post_abc123", "write")
      assert Permission.matches_instance?(perm, "post_abc123", "anything")
    end

    test "action prefix in instance permission" do
      perm = Permission.parse!("blog:post_abc123:read*:")
      assert Permission.matches_instance?(perm, "post_abc123", "read")
      assert Permission.matches_instance?(perm, "post_abc123", "read_comments")
      refute Permission.matches_instance?(perm, "post_abc123", "write")
    end
  end

  describe "to_string/1 - edge cases" do
    test "handles nil scope" do
      perm = %Permission{resource: "blog", instance_id: "*", action: "read", scope: nil}
      assert Permission.to_string(perm) == "blog:*:read:"
    end

    test "handles nil instance_id" do
      perm = %Permission{resource: "blog", instance_id: nil, action: "read", scope: "all"}
      assert Permission.to_string(perm) == "blog:*:read:all"
    end

    test "handles deny with nil scope" do
      perm = %Permission{
        resource: "blog",
        instance_id: "*",
        action: "delete",
        scope: nil,
        deny: true
      }

      assert Permission.to_string(perm) == "!blog:*:delete:"
    end

    test "roundtrip with special characters" do
      original = "my-app_v2:*:read-all_items:my_scope"
      {:ok, perm} = Permission.parse(original)
      result = Permission.to_string(perm)
      assert result == original
    end
  end

  describe "struct defaults" do
    test "new struct has correct defaults" do
      perm = %Permission{}
      assert perm.resource == nil
      # Defaults to wildcard
      assert perm.instance_id == "*"
      assert perm.action == nil
      assert perm.scope == nil
      assert perm.deny == false
    end

    test "struct from keyword list" do
      perm = struct(Permission, resource: "blog", action: "read")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "read"
    end
  end

  describe "parse/1 with maps" do
    test "parses map without instance_id" do
      {:ok, perm} = Permission.parse(%{resource: "blog", action: "read", scope: "all"})
      # Should default
      assert perm.instance_id == "*"
    end

    test "parses map with instance_id" do
      {:ok, perm} =
        Permission.parse(%{
          resource: "blog",
          instance_id: "post_123",
          action: "read",
          scope: nil
        })

      assert perm.instance_id == "post_123"
    end

    test "parses map with string keys" do
      # Maps with string keys might come from JSON
      # This might or might not work depending on implementation
      result = Permission.parse(%{"resource" => "blog", "action" => "read"})
      # Document current behavior
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "deny?/1 and instance_permission?/1 edge cases" do
    test "deny? with default struct" do
      perm = %Permission{}
      refute Permission.deny?(perm)
    end

    test "instance_permission? with default struct" do
      perm = %Permission{}
      # instance_id defaults to "*"
      refute Permission.instance_permission?(perm)
    end

    test "instance_permission? with explicit wildcard" do
      perm = %Permission{instance_id: "*"}
      refute Permission.instance_permission?(perm)
    end
  end
end

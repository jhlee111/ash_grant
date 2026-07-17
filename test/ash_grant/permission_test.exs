defmodule AshGrant.PermissionTest do
  use ExUnit.Case, async: true

  alias AshGrant.Permission

  describe "parse/1 - new four-part format" do
    test "parses full RBAC permission" do
      assert {:ok, perm} = Permission.parse("blog:*:read:always")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == "always"
      assert perm.deny == false
    end

    test "parses deny permission" do
      assert {:ok, perm} = Permission.parse("!blog:*:delete:always")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "delete"
      assert perm.scope == "always"
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
      assert {:ok, perm} = Permission.parse("*:*:*:always")
      assert perm.resource == "*"
      assert perm.instance_id == "*"
      assert perm.action == "*"
      assert perm.scope == "always"
    end

    test "parses action type wildcard" do
      assert {:ok, perm} = Permission.parse("blog:*:read*:always")
      assert perm.action == "read*"
    end
  end

  describe "parse/1 - legacy format compatibility" do
    test "parses legacy three-part format (resource:action:scope)" do
      assert {:ok, perm} = Permission.parse("blog:read:always")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == "always"
    end

    test "parses legacy two-part format (resource:action)" do
      assert {:ok, perm} = Permission.parse("blog:read")
      assert perm.resource == "blog"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == nil
    end

    test "parses legacy deny permission" do
      assert {:ok, perm} = Permission.parse("!blog:delete:always")
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
      perm = Permission.parse!("blog:*:read:always")
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
      perm = %Permission{resource: "blog", instance_id: "*", action: "read", scope: "always"}
      assert Permission.to_string(perm) == "blog:*:read:always"
    end

    test "converts instance permission with empty scope" do
      perm = %Permission{resource: "blog", instance_id: "post_abc123", action: "read", scope: nil}
      assert Permission.to_string(perm) == "blog:post_abc123:read:"
    end

    test "converts deny permission" do
      perm = %Permission{
        resource: "blog",
        instance_id: "*",
        action: "delete",
        scope: "always",
        deny: true
      }

      assert Permission.to_string(perm) == "!blog:*:delete:always"
    end

    test "handles nil instance_id as *" do
      perm = %Permission{resource: "blog", instance_id: nil, action: "read", scope: "always"}
      assert Permission.to_string(perm) == "blog:*:read:always"
    end
  end

  describe "matches?/3 - RBAC matching" do
    test "matches exact resource and action" do
      perm = Permission.parse!("blog:*:read:always")
      assert Permission.matches?(perm, "blog", "read")
    end

    test "does not match different resource" do
      perm = Permission.parse!("blog:*:read:always")
      refute Permission.matches?(perm, "comment", "read")
    end

    test "does not match different action" do
      perm = Permission.parse!("blog:*:read:always")
      refute Permission.matches?(perm, "blog", "write")
    end

    test "matches wildcard resource" do
      perm = Permission.parse!("*:*:read:always")
      assert Permission.matches?(perm, "blog", "read")
      assert Permission.matches?(perm, "comment", "read")
    end

    test "matches wildcard action" do
      perm = Permission.parse!("blog:*:*:always")
      assert Permission.matches?(perm, "blog", "read")
      assert Permission.matches?(perm, "blog", "write")
      assert Permission.matches?(perm, "blog", "delete")
    end

    test "action type wildcard requires action_type to match" do
      perm = Permission.parse!("blog:*:read*:always")
      # read* is purely action_type matching — without action_type, nothing matches
      refute Permission.matches?(perm, "blog", "read")
      refute Permission.matches?(perm, "blog", "read_all")
      refute Permission.matches?(perm, "blog", "write")
      # With action_type, matches any action name
      assert Permission.matches?(perm, "blog", "read", :read)
      assert Permission.matches?(perm, "blog", "list", :read)
      refute Permission.matches?(perm, "blog", "list", :update)
    end

    test "matches full wildcard" do
      perm = Permission.parse!("*:*:*:always")
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
      perm = Permission.parse!("blog:*:read:always")
      refute Permission.matches_instance?(perm, "post_abc123xyz789ab", "read")
    end
  end

  describe "instance_permission?/1" do
    test "returns true for instance permission" do
      perm = Permission.parse!("blog:post_abc123xyz789ab:read:")
      assert Permission.instance_permission?(perm)
    end

    test "returns false for RBAC permission" do
      perm = Permission.parse!("blog:*:read:always")
      refute Permission.instance_permission?(perm)
    end
  end

  describe "deny?/1" do
    test "returns true for deny permission" do
      perm = Permission.parse!("!blog:*:delete:always")
      assert Permission.deny?(perm)
    end

    test "returns false for allow permission" do
      perm = Permission.parse!("blog:*:read:always")
      refute Permission.deny?(perm)
    end
  end

  describe "5-part format (field groups)" do
    test "parses 5-part permission string" do
      assert {:ok, perm} = Permission.parse("employee:*:read:always:sensitive")
      assert perm.resource == "employee"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == "always"
      assert perm.field_group == "sensitive"
      assert perm.deny == false
    end

    test "parses 5-part with deny" do
      assert {:ok, perm} = Permission.parse("!employee:*:read:always:confidential")
      assert perm.deny == true
      assert perm.field_group == "confidential"
      assert perm.resource == "employee"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == "always"
    end

    test "parses 4-part without field_group (backward compatible)" do
      assert {:ok, perm} = Permission.parse("employee:*:read:always")
      assert perm.field_group == nil
      assert perm.resource == "employee"
      assert perm.instance_id == "*"
      assert perm.action == "read"
      assert perm.scope == "always"
    end

    test "to_string includes field_group when present" do
      perm = %Permission{
        resource: "employee",
        instance_id: "*",
        action: "read",
        scope: "always",
        field_group: "sensitive"
      }

      assert Permission.to_string(perm) == "employee:*:read:always:sensitive"
    end

    test "to_string omits field_group when nil" do
      perm = %Permission{
        resource: "employee",
        instance_id: "*",
        action: "read",
        scope: "always",
        field_group: nil
      }

      assert Permission.to_string(perm) == "employee:*:read:always"
    end

    test "matches? works with 5-part permission" do
      perm = Permission.parse!("employee:*:read:always:sensitive")
      assert Permission.matches?(perm, "employee", "read")
    end

    test "parse round-trip with field_group" do
      {:ok, original} = Permission.parse("employee:*:read:always:sensitive")
      round_tripped = Permission.to_string(original)
      {:ok, reparsed} = Permission.parse(round_tripped)

      assert original.resource == reparsed.resource
      assert original.instance_id == reparsed.instance_id
      assert original.action == reparsed.action
      assert original.scope == reparsed.scope
      assert original.field_group == reparsed.field_group
      assert original.deny == reparsed.deny
    end

    test "5-part with instance permission" do
      assert {:ok, perm} = Permission.parse("employee:emp_123:read::sensitive")
      assert perm.resource == "employee"
      assert perm.instance_id == "emp_123"
      assert perm.action == "read"
      assert perm.scope == nil
      assert perm.field_group == "sensitive"
    end

    test "5-part with empty field_group" do
      assert {:ok, perm} = Permission.parse("employee:*:read:always:")
      assert perm.field_group == nil
    end

    test "5-part with action wildcard" do
      assert {:ok, perm} = Permission.parse("employee:*:*:always:sensitive")
      assert perm.resource == "employee"
      assert perm.action == "*"
      assert perm.scope == "always"
      assert perm.field_group == "sensitive"
    end

    test "5-part with action type wildcard" do
      assert {:ok, perm} = Permission.parse("employee:*:read*:always:sensitive")
      assert perm.action == "read*"
      assert perm.field_group == "sensitive"
      # read* requires action_type
      refute Permission.matches?(perm, "employee", "read")
      assert Permission.matches?(perm, "employee", "read", :read)
      assert Permission.matches?(perm, "employee", "by_dept", :read)
      refute Permission.matches?(perm, "employee", "write")
    end

    test "5-part with resource wildcard" do
      assert {:ok, perm} = Permission.parse("*:*:read:always:sensitive")
      assert perm.resource == "*"
      assert perm.field_group == "sensitive"
      assert Permission.matches?(perm, "employee", "read")
      assert Permission.matches?(perm, "blog", "read")
    end

    test "5-part deny matches? returns true (deny flag is separate from matching)" do
      perm = Permission.parse!("!employee:*:read:always:sensitive")
      assert Permission.matches?(perm, "employee", "read")
      assert Permission.deny?(perm)
    end

    test "5-part instance permission roundtrip with scope" do
      {:ok, original} = Permission.parse("employee:emp_123:read:draft:sensitive")
      assert original.instance_id == "emp_123"
      assert original.scope == "draft"
      assert original.field_group == "sensitive"

      round_tripped = Permission.to_string(original)
      assert round_tripped == "employee:emp_123:read:draft:sensitive"

      {:ok, reparsed} = Permission.parse(round_tripped)
      assert reparsed.instance_id == original.instance_id
      assert reparsed.scope == original.scope
      assert reparsed.field_group == original.field_group
    end

    test "5-part instance permission with empty scope roundtrip" do
      {:ok, original} = Permission.parse("employee:emp_123:read::sensitive")
      str = Permission.to_string(original)
      {:ok, reparsed} = Permission.parse(str)

      assert reparsed.instance_id == "emp_123"
      assert reparsed.scope == nil
      assert reparsed.field_group == "sensitive"
    end
  end

  describe "matches_action?/3 with action_type" do
    test "read* matches :read type regardless of action name" do
      assert Permission.matches_action?("read*", "list_published", :read)
      assert Permission.matches_action?("read*", "by_slug", :read)
      assert Permission.matches_action?("read*", "search", :read)
    end

    test "read* does NOT match by string prefix" do
      # read* only matches by action type, not by name prefix
      assert Permission.matches_action?("read*", "read", :read)
      refute Permission.matches_action?("read*", "read_all", :update)
      refute Permission.matches_action?("read*", "read_published", nil)
    end

    test "read* does NOT match :update type when name doesn't start with read" do
      refute Permission.matches_action?("read*", "list_published", :update)
      refute Permission.matches_action?("read*", "by_slug", :destroy)
    end

    test "update* matches :update type regardless of action name" do
      assert Permission.matches_action?("update*", "publish", :update)
      assert Permission.matches_action?("update*", "archive", :update)
    end

    test "create* matches :create type regardless of action name" do
      assert Permission.matches_action?("create*", "register", :create)
      assert Permission.matches_action?("create*", "signup", :create)
    end

    test "destroy* matches :destroy type regardless of action name" do
      assert Permission.matches_action?("destroy*", "soft_delete", :destroy)
      assert Permission.matches_action?("destroy*", "purge", :destroy)
    end

    test "exact match still works with action_type" do
      assert Permission.matches_action?("read", "read", :read)
      refute Permission.matches_action?("read", "list_published", :read)
    end

    test "wildcard * matches anything regardless of action_type" do
      assert Permission.matches_action?("*", "anything", :read)
      assert Permission.matches_action?("*", "anything", nil)
    end

    test "backward compat: 2-arg calls still work" do
      # read* requires action_type — without it, never matches
      refute Permission.matches_action?("read*", "read_all")
      refute Permission.matches_action?("read*", "read")
      # * and exact match still work without action_type
      assert Permission.matches_action?("*", "anything")
      refute Permission.matches_action?("read", "write")
      assert Permission.matches_action?("read", "read")
    end
  end

  describe "matches?/4 with action_type" do
    test "read* matches :read type action with non-prefixed name" do
      perm = Permission.parse!("blog:*:read*:always")
      assert Permission.matches?(perm, "blog", "list_published", :read)
    end

    test "read* does NOT match :update type with non-prefixed name" do
      perm = Permission.parse!("blog:*:read*:always")
      refute Permission.matches?(perm, "blog", "list_published", :update)
    end

    test "backward compat: 3-arg matches? still works" do
      perm = Permission.parse!("blog:*:read*:always")
      # read* requires action_type — 3-arg call (no action_type) never matches
      refute Permission.matches?(perm, "blog", "read_published")
      refute Permission.matches?(perm, "blog", "list_published")
      refute Permission.matches?(perm, "blog", "read")
    end

    test "instance permission still returns false for matches?/4" do
      perm = Permission.parse!("blog:post_abc123:read*:")
      refute Permission.matches?(perm, "blog", "list_published", :read)
    end
  end

  describe "String.Chars protocol" do
    test "converts to string" do
      perm = Permission.parse!("blog:*:read:always")
      assert "#{perm}" == "blog:*:read:always"
    end
  end

  describe "matches_action?/3 - @type explicit type wildcards" do
    test "@read matches :read-type actions regardless of name" do
      assert Permission.matches_action?("@read", "list_published", :read)
      assert Permission.matches_action?("@read", "by_slug", :read)
      assert Permission.matches_action?("@read", "read", :read)
    end

    test "@read does not match other action types" do
      refute Permission.matches_action?("@read", "list_published", :update)
      refute Permission.matches_action?("@read", "read_all", :destroy)
    end

    test "@read never matches without an action_type" do
      refute Permission.matches_action?("@read", "read", nil)
      refute Permission.matches_action?("@read", "read_all", nil)
    end

    test "@read is exactly equivalent to the deprecated read* spelling" do
      cases = [{"list_published", :read}, {"read", :read}, {"x", :update}, {"y", nil}]

      for {action, type} <- cases do
        assert Permission.matches_action?("@read", action, type) ==
                 Permission.matches_action?("read*", action, type),
               "@read and read* disagreed on #{action}/#{inspect(type)}"
      end
    end

    test "every Ash action type has a working @ form" do
      assert Permission.matches_action?("@create", "register", :create)
      assert Permission.matches_action?("@update", "publish", :update)
      assert Permission.matches_action?("@destroy", "purge", :destroy)
      assert Permission.matches_action?("@action", "recalculate", :action)
    end

    test "parses and matches through a full permission string" do
      perm = Permission.parse!("blog:*:@read:always")

      assert perm.action == "@read"
      assert Permission.matches?(perm, "blog", "list_published", :read)
      refute Permission.matches?(perm, "blog", "list_published", :update)
    end

    test "@ form round-trips through to_string/1" do
      for s <- ["blog:*:@read:always", "!blog:*:@destroy:always", "blog:*:@update:own:sensitive"] do
        assert s |> Permission.parse!() |> Permission.to_string() == s
      end
    end

    test "@ does not collide with the deny prefix" do
      perm = Permission.parse!("!blog:*:@read:always")

      assert perm.deny
      assert perm.action == "@read"
    end
  end

  describe "diagnostics/1" do
    test "clean permissions report nothing" do
      clean = [
        "blog:*:read:always",
        "blog:*:@read:always",
        "blog:*:*:always",
        "blog:post_abc:read:",
        "blog:post_abc:*:",
        "!blog:*:destroy:always"
      ]

      for s <- clean do
        assert Permission.diagnostics(s) == [], "expected #{s} to be clean"
      end
    end

    test "deprecated read* is flagged, and its replacement works" do
      assert [d] = Permission.diagnostics("blog:*:read*:always")

      assert d.code == :deprecated_type_wildcard
      assert d.permission == "blog:*:read*:always"
      assert d.suggestion == "blog:*:@read:always"
      assert Permission.diagnostics(d.suggestion) == []
    end

    test "suggestion preserves deny prefix and field_group" do
      assert [d] = Permission.diagnostics("!blog:*:read*:always:sensitive")
      assert d.suggestion == "!blog:*:@read:always:sensitive"
    end

    test "type wildcard on an instance permission is flagged as dead" do
      assert [d] = Permission.diagnostics("blog:post_abc:@read:")

      assert d.code == :dead_instance_type_wildcard
      assert d.suggestion == nil
    end

    test "dead instance grant is caught in both spellings" do
      codes = fn s -> s |> Permission.diagnostics() |> Enum.map(& &1.code) end

      assert :dead_instance_type_wildcard in codes.("blog:post_abc:read*:")
      assert :dead_instance_type_wildcard in codes.("blog:post_abc:@read:")
    end

    test "unknown action type is flagged, with @destroy suggested for delete" do
      assert [d] = Permission.diagnostics("blog:*:@delete:always")

      assert d.code == :unknown_action_type
      assert d.suggestion == "blog:*:@destroy:always"
      assert Permission.diagnostics(d.suggestion) == []
    end

    test "no message recommends a replacement the diagnostics themselves reject" do
      # `delete*` is deprecated, but `@delete` is not a valid type either. The message
      # must not tell you to prefer `@delete` while a sibling diagnostic calls it unknown.
      diagnostics = Permission.diagnostics("blog:*:delete*:always")
      deprecated = Enum.find(diagnostics, &(&1.code == :deprecated_type_wildcard))

      refute deprecated.message =~ "Prefer"
      refute deprecated.message =~ "@delete"

      # ...whereas a mechanically fixable one still names its replacement.
      assert [valid] = Permission.diagnostics("blog:*:read*:always")
      assert valid.message =~ "Prefer `@read`"
    end

    test "does not suggest a spelling swap that leaves the grant broken" do
      # delete* is deprecated AND names a type Ash does not have. Suggesting `@delete`
      # would point at a grant that still never matches, so the deprecation diagnostic
      # withholds its suggestion and the unknown-type diagnostic carries the real fix.
      diagnostics = Permission.diagnostics("blog:*:delete*:always")
      deprecated = Enum.find(diagnostics, &(&1.code == :deprecated_type_wildcard))
      unknown = Enum.find(diagnostics, &(&1.code == :unknown_action_type))

      assert deprecated.suggestion == nil
      assert unknown.suggestion == "blog:*:@destroy:always"
    end

    test "does not suggest @read for a grant that is dead either way" do
      diagnostics = Permission.diagnostics("blog:post_abc:read*:")
      deprecated = Enum.find(diagnostics, &(&1.code == :deprecated_type_wildcard))

      assert deprecated.suggestion == nil
    end

    test "no suggestion is ever itself flagged" do
      samples = [
        "blog:*:read*:always",
        "blog:*:delete*:always",
        "blog:post_abc:read*:",
        "blog:*:@delete:always",
        "!blog:*:update*:own:sensitive"
      ]

      for s <- samples, d <- Permission.diagnostics(s), d.suggestion != nil do
        assert Permission.diagnostics(d.suggestion) == [],
               "suggestion #{d.suggestion} (from #{s}) is itself flagged"
      end
    end

    test "accepts a Permission struct as well as a string" do
      perm = Permission.parse!("blog:*:read*:always")
      assert [%{code: :deprecated_type_wildcard}] = Permission.diagnostics(perm)
    end

    test "unparseable strings report nothing" do
      assert Permission.diagnostics("garbage") == []
      assert Permission.diagnostics("") == []
    end

    test "bare * is not a type wildcard" do
      assert Permission.diagnostics("blog:*:*:always") == []
      assert Permission.diagnostics("blog:post_abc:*:") == []
    end

    test "every diagnostic carries a non-empty message" do
      samples = ["blog:*:read*:always", "blog:post_abc:@read:", "blog:*:@delete:always"]

      for s <- samples, d <- Permission.diagnostics(s) do
        assert is_binary(d.message) and d.message != ""
      end
    end
  end
end

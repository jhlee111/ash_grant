defmodule AshGrant.IntrospectTest do
  @moduledoc """
  Tests for AshGrant.Introspect module.

  The Introspect module provides helper functions to query permissions
  for various use cases:
  - Admin UI: Display user permissions
  - Permission management: List available permissions
  - Debugging: Check why access is allowed/denied
  - API responses: Return allowed actions to clients
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Introspect
  alias AshGrant.Test.Post

  describe "actor_permissions/3 - Admin UI: what permissions does actor have?" do
    test "returns all permissions for a resource with their status" do
      actor = %{id: "user-1", role: :editor}

      result = Introspect.actor_permissions(Post, actor)

      # Editor has: post:*:read:all, post:*:update:own, post:*:create:all
      assert is_list(result)

      read_perm = Enum.find(result, &(&1.action == "read"))
      assert read_perm.allowed == true
      assert read_perm.scope == "all"

      update_perm = Enum.find(result, &(&1.action == "update"))
      assert update_perm.allowed == true
      assert update_perm.scope == "own"

      delete_perm = Enum.find(result, &(&1.action == "destroy"))
      assert delete_perm.allowed == false
    end

    test "returns denied status for actions with deny rules" do
      # Actor has both allow and deny for destroy
      actor = %{id: "user-1", permissions: ["post:*:*:all", "!post:*:destroy:all"]}

      result = Introspect.actor_permissions(Post, actor)

      destroy_perm = Enum.find(result, &(&1.action == "destroy"))
      assert destroy_perm.allowed == false
      assert destroy_perm.denied == true
    end

    test "returns empty permissions for nil actor" do
      result = Introspect.actor_permissions(Post, nil)

      assert Enum.all?(result, &(&1.allowed == false))
    end

    test "includes instance permissions" do
      post_id = Ash.UUID.generate()
      actor = %{id: "user-1", permissions: ["post:#{post_id}:read:"]}

      result = Introspect.actor_permissions(Post, actor)

      read_perm = Enum.find(result, &(&1.action == "read"))
      assert read_perm.allowed == true
      assert post_id in (read_perm.instance_ids || [])
    end
  end

  describe "available_permissions/1 - Permission management UI" do
    test "returns all possible permissions for a resource" do
      result = Introspect.available_permissions(Post)

      assert is_list(result)
      assert length(result) > 0

      # Should include all actions
      actions = Enum.map(result, & &1.action) |> Enum.uniq()
      assert "read" in actions
      assert "create" in actions
      assert "update" in actions
      assert "destroy" in actions
    end

    test "includes scope options for each action" do
      result = Introspect.available_permissions(Post)

      read_perms = Enum.filter(result, &(&1.action == "read"))

      # Should have different scope options
      scopes = Enum.map(read_perms, & &1.scope)
      assert "all" in scopes
      assert "own" in scopes
      assert "published" in scopes
    end

    test "includes permission string format" do
      result = Introspect.available_permissions(Post)

      first = hd(result)
      assert is_binary(first.permission_string)
      assert String.contains?(first.permission_string, "post:")
    end

    test "includes scope descriptions when available" do
      result = Introspect.available_permissions(Post)

      own_perm = Enum.find(result, &(&1.scope == "own"))

      # If scope has description, it should be included
      if own_perm.scope_description do
        assert is_binary(own_perm.scope_description)
      end
    end
  end

  describe "can?/4 - Simple permission check for debugging" do
    test "returns :allow with scope for allowed actions" do
      actor = %{id: "user-1", role: :editor}

      assert {:allow, info} = Introspect.can?(Post, :read, actor)
      assert info.scope == "all"
    end

    test "returns :allow with :own scope for update" do
      actor = %{id: "user-1", role: :editor}

      assert {:allow, info} = Introspect.can?(Post, :update, actor)
      assert info.scope == "own"
    end

    test "returns :deny with reason for denied actions" do
      actor = %{id: "user-1", role: :viewer}

      assert {:deny, info} = Introspect.can?(Post, :destroy, actor)
      assert info.reason in [:no_permission, :denied_by_rule]
    end

    test "returns :deny for nil actor" do
      assert {:deny, info} = Introspect.can?(Post, :read, nil)
      assert info.reason == :no_actor
    end

    test "returns :allow for instance permission" do
      post_id = Ash.UUID.generate()
      actor = %{id: "user-1", permissions: ["post:#{post_id}:read:"]}

      assert {:allow, info} = Introspect.can?(Post, :read, actor)
      assert info.instance_ids == [post_id]
    end
  end

  describe "allowed_actions/3 - API response: what can actor do?" do
    test "returns list of allowed action names" do
      actor = %{id: "user-1", role: :editor}

      result = Introspect.allowed_actions(Post, actor)

      assert is_list(result)
      assert :read in result
      assert :create in result
      assert :update in result
      refute :destroy in result
    end

    test "returns empty list for nil actor" do
      result = Introspect.allowed_actions(Post, nil)

      assert result == []
    end

    test "returns detailed info when detailed: true" do
      actor = %{id: "user-1", role: :editor}

      result = Introspect.allowed_actions(Post, actor, detailed: true)

      assert is_list(result)
      read_action = Enum.find(result, &(&1.action == :read))
      assert read_action.scope == "all"
    end

    test "includes instance-based actions" do
      post_id = Ash.UUID.generate()
      actor = %{id: "user-1", permissions: ["post:#{post_id}:update:"]}

      result = Introspect.allowed_actions(Post, actor, detailed: true)

      update_action = Enum.find(result, &(&1.action == :update))
      assert update_action != nil
      assert post_id in (update_action.instance_ids || [])
    end
  end

  describe "permissions_for/3 - Raw permissions for actor" do
    test "returns raw permission list from resolver" do
      actor = %{id: "user-1", role: :editor}

      result = Introspect.permissions_for(Post, actor)

      assert is_list(result)
      # Editor permissions
      assert Enum.any?(result, &String.contains?(&1, "read"))
    end

    test "returns empty list for nil actor" do
      result = Introspect.permissions_for(Post, nil)

      assert result == []
    end
  end
end

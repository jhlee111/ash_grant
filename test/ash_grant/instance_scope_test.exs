defmodule AshGrant.InstanceScopeTest do
  @moduledoc """
  Tests for instance permissions with scopes (Issue #1).

  Instance permissions should support scope conditions, treating scope as an
  "authorization condition" rather than just a "record filter".

  Use cases:
  - Status-based: `doc:doc_123:update:draft` – editing only when document is in draft
  - Time-based: `doc:doc_123:read:business_hours` – viewing restricted to business hours
  - Amount-based: `invoice:inv_456:approve:small_amount` – approval only below threshold
  """
  use ExUnit.Case, async: true

  alias AshGrant.Evaluator
  alias AshGrant.Permission

  describe "Permission parsing with instance scopes" do
    test "parses instance permission with scope" do
      {:ok, perm} = Permission.parse("doc:doc_123:update:draft")

      assert perm.resource == "doc"
      assert perm.instance_id == "doc_123"
      assert perm.action == "update"
      assert perm.scope == "draft"
      assert perm.deny == false
    end

    test "parses instance permission with empty scope (backward compatible)" do
      {:ok, perm} = Permission.parse("doc:doc_123:read:")

      assert perm.resource == "doc"
      assert perm.instance_id == "doc_123"
      assert perm.action == "read"
      assert perm.scope == nil
    end

    test "parses deny instance permission with scope" do
      {:ok, perm} = Permission.parse("!doc:doc_123:delete:archived")

      assert perm.resource == "doc"
      assert perm.instance_id == "doc_123"
      assert perm.action == "delete"
      assert perm.scope == "archived"
      assert perm.deny == true
    end

    test "converts instance permission with scope to string" do
      perm = %Permission{
        resource: "invoice",
        instance_id: "inv_456",
        action: "approve",
        scope: "small_amount",
        deny: false
      }

      assert Permission.to_string(perm) == "invoice:inv_456:approve:small_amount"
    end
  end

  describe "Evaluator.has_instance_access?/3 with scopes" do
    test "grants access when instance permission has matching scope" do
      permissions = ["doc:doc_123:update:draft"]
      assert Evaluator.has_instance_access?(permissions, "doc_123", "update")
    end

    test "grants access with empty scope (backward compatible)" do
      permissions = ["doc:doc_123:read:"]
      assert Evaluator.has_instance_access?(permissions, "doc_123", "read")
    end

    test "denies access when instance_id doesn't match" do
      permissions = ["doc:doc_123:update:draft"]
      refute Evaluator.has_instance_access?(permissions, "doc_456", "update")
    end

    test "deny wins with instance scopes" do
      permissions = [
        "doc:doc_123:*:draft",
        "!doc:doc_123:delete:draft"
      ]

      assert Evaluator.has_instance_access?(permissions, "doc_123", "read")
      refute Evaluator.has_instance_access?(permissions, "doc_123", "delete")
    end
  end

  describe "Evaluator.get_instance_scope/3" do
    test "returns scope from instance permission" do
      permissions = ["doc:doc_123:update:draft"]
      assert Evaluator.get_instance_scope(permissions, "doc_123", "update") == "draft"
    end

    test "returns nil for empty scope" do
      permissions = ["doc:doc_123:read:"]
      assert Evaluator.get_instance_scope(permissions, "doc_123", "read") == nil
    end

    test "returns nil when no match" do
      permissions = ["doc:doc_123:read:draft"]
      assert Evaluator.get_instance_scope(permissions, "doc_456", "read") == nil
    end

    test "returns nil when denied" do
      permissions = [
        "doc:doc_123:*:all",
        "!doc:doc_123:delete:all"
      ]

      assert Evaluator.get_instance_scope(permissions, "doc_123", "read") == "all"
      assert Evaluator.get_instance_scope(permissions, "doc_123", "delete") == nil
    end

    test "returns first matching scope for instance" do
      permissions = [
        "doc:doc_123:update:draft",
        "doc:doc_123:update:pending"
      ]

      assert Evaluator.get_instance_scope(permissions, "doc_123", "update") == "draft"
    end
  end

  describe "Evaluator.get_all_instance_scopes/3" do
    test "returns all scopes from matching instance permissions" do
      permissions = [
        "doc:doc_123:read:draft",
        "doc:doc_123:read:internal",
        "doc:doc_123:read:public"
      ]

      scopes = Evaluator.get_all_instance_scopes(permissions, "doc_123", "read")

      assert "draft" in scopes
      assert "internal" in scopes
      assert "public" in scopes
    end

    test "returns empty list when denied" do
      permissions = [
        "doc:doc_123:*:all",
        "!doc:doc_123:delete:all"
      ]

      assert Evaluator.get_all_instance_scopes(permissions, "doc_123", "delete") == []
    end

    test "returns unique scopes" do
      permissions = [
        "doc:doc_123:read:draft",
        "doc:doc_123:*:draft"
      ]

      scopes = Evaluator.get_all_instance_scopes(permissions, "doc_123", "read")
      assert scopes == ["draft"]
    end

    test "filters out nil scopes" do
      permissions = [
        "doc:doc_123:read:",
        "doc:doc_123:read:public"
      ]

      scopes = Evaluator.get_all_instance_scopes(permissions, "doc_123", "read")
      assert scopes == ["public"]
    end
  end

  describe "Permission.matches_instance?/3 behavior" do
    test "matches instance regardless of scope value" do
      perm = Permission.parse!("doc:doc_123:update:draft")
      assert Permission.matches_instance?(perm, "doc_123", "update")
    end

    test "RBAC permission still does not match instance" do
      perm = Permission.parse!("doc:*:update:draft")
      refute Permission.matches_instance?(perm, "doc_123", "update")
    end
  end
end

defmodule AshGrant.PermissionableTest do
  use ExUnit.Case, async: true

  alias AshGrant.{Permission, PermissionInput, Permissionable}
  alias AshGrant.Evaluator

  describe "Permissionable protocol for BitString" do
    test "converts string to PermissionInput" do
      input = Permissionable.to_permission_input("post:*:read:all")

      assert %PermissionInput{} = input
      assert input.string == "post:*:read:all"
      assert input.description == nil
      assert input.source == nil
      assert input.metadata == nil
    end
  end

  describe "Permissionable protocol for PermissionInput" do
    test "returns PermissionInput as-is" do
      original = %PermissionInput{
        string: "post:*:read:all",
        description: "Read all posts",
        source: "admin_role"
      }

      result = Permissionable.to_permission_input(original)
      assert result == original
    end
  end

  describe "Permissionable protocol for Permission" do
    test "converts Permission to PermissionInput" do
      permission = Permission.parse!("post:*:read:all")
      input = Permissionable.to_permission_input(permission)

      assert %PermissionInput{} = input
      assert input.string == "post:*:read:all"
    end

    test "preserves deny prefix in conversion" do
      permission = Permission.parse!("!post:*:delete:all")
      input = Permissionable.to_permission_input(permission)

      assert input.string == "!post:*:delete:all"
    end
  end

  describe "PermissionInput struct" do
    test "new/1 creates with just string" do
      input = PermissionInput.new("post:*:read:all")

      assert input.string == "post:*:read:all"
      assert input.description == nil
      assert input.source == nil
    end

    test "new/2 creates with options" do
      input =
        PermissionInput.new("post:*:read:all",
          description: "Read posts",
          source: "editor_role",
          metadata: %{granted_at: ~U[2024-01-15 10:00:00Z]}
        )

      assert input.string == "post:*:read:all"
      assert input.description == "Read posts"
      assert input.source == "editor_role"
      assert input.metadata == %{granted_at: ~U[2024-01-15 10:00:00Z]}
    end

    test "to_string returns the permission string" do
      input = %PermissionInput{
        string: "post:*:read:all",
        description: "Read posts"
      }

      assert PermissionInput.to_string(input) == "post:*:read:all"
      assert to_string(input) == "post:*:read:all"
    end
  end

  describe "Permission.from_input/1" do
    test "creates Permission from PermissionInput preserving metadata" do
      input = %PermissionInput{
        string: "blog:*:read:all",
        description: "Read all blogs",
        source: "editor_role",
        metadata: %{key: "value"}
      }

      permission = Permission.from_input(input)

      assert %Permission{} = permission
      assert permission.resource == "blog"
      assert permission.instance_id == "*"
      assert permission.action == "read"
      assert permission.scope == "all"
      assert permission.deny == false
      assert permission.description == "Read all blogs"
      assert permission.source == "editor_role"
      assert permission.metadata == %{key: "value"}
    end

    test "handles deny prefix" do
      input = %PermissionInput{
        string: "!blog:*:delete:all",
        description: "Cannot delete blogs"
      }

      permission = Permission.from_input(input)

      assert permission.deny == true
      assert permission.description == "Cannot delete blogs"
    end

    test "handles instance permissions" do
      input = %PermissionInput{
        string: "blog:post_abc123:read:",
        source: "direct_grant"
      }

      permission = Permission.from_input(input)

      assert permission.instance_id == "post_abc123"
      assert permission.scope == nil
      assert permission.source == "direct_grant"
    end
  end

  describe "Evaluator with PermissionInput" do
    test "has_access? works with PermissionInput" do
      permissions = [
        %PermissionInput{
          string: "blog:*:read:all",
          description: "Read blogs"
        }
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      refute Evaluator.has_access?(permissions, "blog", "write")
    end

    test "has_access? works with mixed strings and PermissionInput" do
      permissions = [
        "post:*:read:all",
        %PermissionInput{
          string: "post:*:update:own",
          description: "Edit own posts",
          source: "editor_role"
        }
      ]

      assert Evaluator.has_access?(permissions, "post", "read")
      assert Evaluator.has_access?(permissions, "post", "update")
      refute Evaluator.has_access?(permissions, "post", "delete")
    end

    test "get_scope works with PermissionInput" do
      permissions = [
        %PermissionInput{string: "blog:*:read:all"},
        %PermissionInput{string: "blog:*:update:own"}
      ]

      assert Evaluator.get_scope(permissions, "blog", "read") == "all"
      assert Evaluator.get_scope(permissions, "blog", "update") == "own"
    end

    test "deny-wins with PermissionInput" do
      permissions = [
        %PermissionInput{string: "blog:*:*:all", description: "All access"},
        %PermissionInput{string: "!blog:*:delete:all", description: "Cannot delete"}
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      refute Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "has_instance_access? works with PermissionInput" do
      permissions = [
        %PermissionInput{
          string: "blog:post_abc123xyz789ab:read:",
          source: "direct_share"
        }
      ]

      assert Evaluator.has_instance_access?(permissions, "post_abc123xyz789ab", "read")
      refute Evaluator.has_instance_access?(permissions, "post_xyz789abc123xy", "read")
    end
  end

  describe "Custom struct with Permissionable protocol" do
    defmodule RolePermission do
      defstruct [:permission_string, :label, :role_name]
    end

    defimpl Permissionable, for: RolePermission do
      def to_permission_input(%RolePermission{} = rp) do
        %PermissionInput{
          string: rp.permission_string,
          description: rp.label,
          source: "role:#{rp.role_name}"
        }
      end
    end

    test "custom struct works with Evaluator" do
      permissions = [
        %RolePermission{
          permission_string: "blog:*:read:all",
          label: "Read all blogs",
          role_name: "editor"
        },
        %RolePermission{
          permission_string: "blog:*:update:own",
          label: "Edit own blogs",
          role_name: "editor"
        }
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      assert Evaluator.has_access?(permissions, "blog", "update")
      refute Evaluator.has_access?(permissions, "blog", "delete")
    end

    test "custom struct metadata is preserved through normalization" do
      role_perm = %RolePermission{
        permission_string: "blog:*:read:all",
        label: "Read all blogs",
        role_name: "editor"
      }

      # Convert through the protocol
      input = Permissionable.to_permission_input(role_perm)
      permission = Permission.from_input(input)

      assert permission.description == "Read all blogs"
      assert permission.source == "role:editor"
    end

    test "mixed custom structs and strings work together" do
      permissions = [
        "post:*:read:all",
        %RolePermission{
          permission_string: "post:*:update:own",
          label: "Edit own posts",
          role_name: "author"
        },
        %PermissionInput{
          string: "post:*:create:all",
          description: "Create posts"
        }
      ]

      assert Evaluator.has_access?(permissions, "post", "read")
      assert Evaluator.has_access?(permissions, "post", "update")
      assert Evaluator.has_access?(permissions, "post", "create")
    end
  end

  describe "Permission struct with metadata" do
    test "Permission struct includes metadata fields" do
      permission = %Permission{
        resource: "blog",
        instance_id: "*",
        action: "read",
        scope: "all",
        deny: false,
        description: "Read all blogs",
        source: "admin_role",
        metadata: %{priority: 1}
      }

      assert permission.description == "Read all blogs"
      assert permission.source == "admin_role"
      assert permission.metadata == %{priority: 1}
    end

    test "Permission.parse! sets metadata to nil by default" do
      permission = Permission.parse!("blog:*:read:all")

      assert permission.description == nil
      assert permission.source == nil
      assert permission.metadata == nil
    end

    test "Permission matching ignores metadata" do
      permission = %Permission{
        resource: "blog",
        instance_id: "*",
        action: "read",
        scope: "all",
        description: "Has metadata"
      }

      assert Permission.matches?(permission, "blog", "read")
    end
  end
end

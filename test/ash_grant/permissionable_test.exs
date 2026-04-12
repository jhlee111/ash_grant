defmodule AshGrant.PermissionableTest do
  use ExUnit.Case, async: true

  alias AshGrant.{Permission, PermissionInput, Permissionable}
  alias AshGrant.Evaluator

  describe "Permissionable protocol for BitString" do
    test "converts string to PermissionInput" do
      input = Permissionable.to_permission_input("post:*:read:always")

      assert %PermissionInput{} = input
      assert input.string == "post:*:read:always"
      assert input.description == nil
      assert input.source == nil
      assert input.metadata == nil
    end
  end

  describe "Permissionable protocol for PermissionInput" do
    test "returns PermissionInput as-is" do
      original = %PermissionInput{
        string: "post:*:read:always",
        description: "Read all posts",
        source: "admin_role"
      }

      result = Permissionable.to_permission_input(original)
      assert result == original
    end
  end

  describe "Permissionable protocol for Permission" do
    test "converts Permission to PermissionInput" do
      permission = Permission.parse!("post:*:read:always")
      input = Permissionable.to_permission_input(permission)

      assert %PermissionInput{} = input
      assert input.string == "post:*:read:always"
    end

    test "preserves deny prefix in conversion" do
      permission = Permission.parse!("!post:*:delete:always")
      input = Permissionable.to_permission_input(permission)

      assert input.string == "!post:*:delete:always"
    end
  end

  describe "PermissionInput struct" do
    test "new/1 creates with just string" do
      input = PermissionInput.new("post:*:read:always")

      assert input.string == "post:*:read:always"
      assert input.description == nil
      assert input.source == nil
    end

    test "new/2 creates with options" do
      input =
        PermissionInput.new("post:*:read:always",
          description: "Read posts",
          source: "editor_role",
          metadata: %{granted_at: ~U[2024-01-15 10:00:00Z]}
        )

      assert input.string == "post:*:read:always"
      assert input.description == "Read posts"
      assert input.source == "editor_role"
      assert input.metadata == %{granted_at: ~U[2024-01-15 10:00:00Z]}
    end

    test "to_string returns the permission string" do
      input = %PermissionInput{
        string: "post:*:read:always",
        description: "Read posts"
      }

      assert PermissionInput.to_string(input) == "post:*:read:always"
      assert to_string(input) == "post:*:read:always"
    end
  end

  describe "Permission.from_input/1" do
    test "creates Permission from PermissionInput preserving metadata" do
      input = %PermissionInput{
        string: "blog:*:read:always",
        description: "Read all blogs",
        source: "editor_role",
        metadata: %{key: "value"}
      }

      permission = Permission.from_input(input)

      assert %Permission{} = permission
      assert permission.resource == "blog"
      assert permission.instance_id == "*"
      assert permission.action == "read"
      assert permission.scope == "always"
      assert permission.deny == false
      assert permission.description == "Read all blogs"
      assert permission.source == "editor_role"
      assert permission.metadata == %{key: "value"}
    end

    test "handles deny prefix" do
      input = %PermissionInput{
        string: "!blog:*:delete:always",
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
          string: "blog:*:read:always",
          description: "Read blogs"
        }
      ]

      assert Evaluator.has_access?(permissions, "blog", "read")
      refute Evaluator.has_access?(permissions, "blog", "write")
    end

    test "has_access? works with mixed strings and PermissionInput" do
      permissions = [
        "post:*:read:always",
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
        %PermissionInput{string: "blog:*:read:always"},
        %PermissionInput{string: "blog:*:update:own"}
      ]

      assert Evaluator.get_scope(permissions, "blog", "read") == "always"
      assert Evaluator.get_scope(permissions, "blog", "update") == "own"
    end

    test "deny-wins with PermissionInput" do
      permissions = [
        %PermissionInput{string: "blog:*:*:always", description: "All access"},
        %PermissionInput{string: "!blog:*:delete:always", description: "Cannot delete"}
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
          permission_string: "blog:*:read:always",
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
        permission_string: "blog:*:read:always",
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
        "post:*:read:always",
        %RolePermission{
          permission_string: "post:*:update:own",
          label: "Edit own posts",
          role_name: "author"
        },
        %PermissionInput{
          string: "post:*:create:always",
          description: "Create posts"
        }
      ]

      assert Evaluator.has_access?(permissions, "post", "read")
      assert Evaluator.has_access?(permissions, "post", "update")
      assert Evaluator.has_access?(permissions, "post", "create")
    end

    test "custom struct with 5-part permission works with Evaluator" do
      permissions = [
        %RolePermission{
          permission_string: "employee:*:read:always:sensitive",
          label: "Read sensitive employee data",
          role_name: "hr"
        }
      ]

      assert Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
    end

    test "custom struct 5-part metadata preserved through normalization" do
      role_perm = %RolePermission{
        permission_string: "employee:*:read:always:confidential",
        label: "Read confidential",
        role_name: "director"
      }

      input = Permissionable.to_permission_input(role_perm)
      permission = Permission.from_input(input)

      assert permission.field_group == "confidential"
      assert permission.description == "Read confidential"
      assert permission.source == "role:director"
    end
  end

  describe "5-part PermissionInput" do
    test "converts 5-part string to PermissionInput" do
      input = Permissionable.to_permission_input("employee:*:read:always:sensitive")

      assert %PermissionInput{} = input
      assert input.string == "employee:*:read:always:sensitive"
    end

    test "Permission.from_input preserves field_group from 5-part string" do
      input = %PermissionInput{
        string: "employee:*:read:always:sensitive",
        description: "Read sensitive fields",
        source: "hr_role"
      }

      permission = Permission.from_input(input)

      assert permission.resource == "employee"
      assert permission.action == "read"
      assert permission.scope == "always"
      assert permission.field_group == "sensitive"
      assert permission.description == "Read sensitive fields"
      assert permission.source == "hr_role"
    end

    test "Permission.from_input handles 5-part deny" do
      input = %PermissionInput{
        string: "!employee:*:read:always:confidential",
        description: "Cannot read confidential"
      }

      permission = Permission.from_input(input)

      assert permission.deny == true
      assert permission.field_group == "confidential"
      assert permission.description == "Cannot read confidential"
    end

    test "Permission.from_input handles 5-part instance permission" do
      input = %PermissionInput{
        string: "employee:emp_123:read:draft:sensitive",
        source: "direct_grant"
      }

      permission = Permission.from_input(input)

      assert permission.instance_id == "emp_123"
      assert permission.scope == "draft"
      assert permission.field_group == "sensitive"
      assert permission.source == "direct_grant"
    end

    test "Evaluator works with 5-part PermissionInput" do
      permissions = [
        %PermissionInput{
          string: "employee:*:read:always:sensitive",
          description: "Read sensitive"
        }
      ]

      assert Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
    end

    test "Evaluator deny-wins with 5-part PermissionInput" do
      permissions = [
        %PermissionInput{string: "employee:*:read:always:sensitive"},
        %PermissionInput{string: "!employee:*:read:always"}
      ]

      refute Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.get_all_field_groups(permissions, "employee", "read") == []
    end

    test "mixed 4-part and 5-part PermissionInput" do
      permissions = [
        %PermissionInput{string: "employee:*:read:always:sensitive"},
        %PermissionInput{string: "employee:*:update:own"},
        "employee:*:create:always"
      ]

      assert Evaluator.has_access?(permissions, "employee", "read")
      assert Evaluator.get_field_group(permissions, "employee", "read") == "sensitive"
      assert Evaluator.get_field_group(permissions, "employee", "update") == nil
      assert Evaluator.has_access?(permissions, "employee", "create")
    end
  end

  describe "Permission struct with metadata" do
    test "Permission struct includes metadata fields" do
      permission = %Permission{
        resource: "blog",
        instance_id: "*",
        action: "read",
        scope: "always",
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
      permission = Permission.parse!("blog:*:read:always")

      assert permission.description == nil
      assert permission.source == nil
      assert permission.metadata == nil
    end

    test "Permission matching ignores metadata" do
      permission = %Permission{
        resource: "blog",
        instance_id: "*",
        action: "read",
        scope: "always",
        description: "Has metadata"
      }

      assert Permission.matches?(permission, "blog", "read")
    end
  end
end

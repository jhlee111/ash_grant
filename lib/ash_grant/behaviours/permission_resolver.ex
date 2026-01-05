defmodule AshGrant.PermissionResolver do
  @moduledoc """
  Behaviour for resolving permissions from an actor.

  Implement this behaviour to define how permissions are retrieved
  for a given actor in your application.

  ## Examples

  ### Simple: Permissions stored directly on user

      defmodule MyApp.SimplePermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          actor.permissions || []
        end
      end

  ### Role-based: Permissions from roles

      defmodule MyApp.RolePermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          actor
          |> Map.get(:roles, [])
          |> Enum.flat_map(& &1.permissions)
        end
      end

  ### With metadata for debugging

  Return `AshGrant.PermissionInput` structs for enhanced debugging:

      defmodule MyApp.RichPermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          actor
          |> Map.get(:roles, [])
          |> Enum.flat_map(fn role ->
            Enum.map(role.permissions, fn perm ->
              %AshGrant.PermissionInput{
                string: perm,
                description: "From role permissions",
                source: "role:\#{role.name}"
              }
            end)
          end)
        end
      end

  ### Custom structs with Permissionable protocol

  Implement the `AshGrant.Permissionable` protocol for your custom structs:

      defmodule MyApp.RolePermission do
        defstruct [:permission_string, :label, :role_name]
      end

      defimpl AshGrant.Permissionable, for: MyApp.RolePermission do
        def to_permission_input(%MyApp.RolePermission{} = rp) do
          %AshGrant.PermissionInput{
            string: rp.permission_string,
            description: rp.label,
            source: "role:\#{rp.role_name}"
          }
        end
      end

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          # Just return your structs - AshGrant handles conversion via Protocol
          MyApp.Accounts.get_role_permissions(actor)
        end
      end

  ### Combined: Role + Instance permissions

      defmodule MyApp.CombinedPermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, context) do
          role_permissions = get_role_permissions(actor)
          instance_permissions = get_instance_permissions(actor, context)
          role_permissions ++ instance_permissions
        end

        defp get_role_permissions(actor) do
          actor.roles
          |> Enum.flat_map(& &1.permissions)
        end

        defp get_instance_permissions(actor, %{resource_type: type, resource_id: id}) do
          MyApp.ResourcePermission
          |> MyApp.Repo.all(user_id: actor.id, resource_type: type, resource_id: id)
          |> Enum.flat_map(&expand_to_permissions/1)
        end

        defp get_instance_permissions(_actor, _context), do: []
      end

  """

  @type actor :: any()
  @type context :: map()

  @typedoc """
  A permission can be:
  - A string in permission format (e.g., "blog:*:read:all")
  - An `AshGrant.PermissionInput` struct with metadata
  - An `AshGrant.Permission` struct
  - A map with permission fields
  - Any struct implementing the `AshGrant.Permissionable` protocol
  """
  @type permission ::
          String.t()
          | AshGrant.PermissionInput.t()
          | AshGrant.Permission.t()
          | map()
          | AshGrant.Permissionable.t()

  @doc """
  Resolves permissions for the given actor.

  ## Parameters

  - `actor` - The actor (usually a user) requesting access
  - `context` - Additional context, may include:
    - `:resource` - The resource module being accessed
    - `:resource_type` - The resource type string
    - `:resource_id` - The specific resource ID (for instance permissions)
    - `:action` - The action being performed
    - `:tenant` - The current tenant

  ## Returns

  A list of permissions. Each permission can be:
  - A string in permission format (e.g., "blog:*:read:all")
  - An `AshGrant.PermissionInput` struct with metadata for debugging
  - An `AshGrant.Permission` struct
  - A map with permission fields
  - Any struct implementing the `AshGrant.Permissionable` protocol

  """
  @callback resolve(actor(), context()) :: [permission()]
end

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
  @type permission :: String.t() | AshGrant.Permission.t() | map()

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
  - An `AshGrant.Permission` struct
  - A map with permission fields

  """
  @callback resolve(actor(), context()) :: [permission()]
end

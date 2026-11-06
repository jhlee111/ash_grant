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
  - A string in permission format (e.g., "blog:*:read:always")
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
  - A string in permission format (e.g., "blog:*:read:always")
  - An `AshGrant.PermissionInput` struct with metadata for debugging
  - An `AshGrant.Permission` struct
  - A map with permission fields
  - Any struct implementing the `AshGrant.Permissionable` protocol

  """
  @callback resolve(actor(), context()) :: [permission()]

  @doc """
  Optional. Loads an actor given an identifier (e.g., primary key).

  This callback powers identifier-based introspection entry points such as
  `AshGrant.Introspect.explain_by_identifier/1` and
  `AshGrant.Introspect.can_by_identifier/3`, where the caller (an admin
  dashboard, LLM tool, `mix ash_grant.explain` task, etc.) only knows the
  actor's ID — not the fully-hydrated struct.

  Implementations should fetch the actor from the underlying data store
  and return it in the same shape that `resolve/2` expects.

  ## Return values

  - `{:ok, actor}` - the loaded actor
  - `:error` - when no actor exists for the given identifier

  ## Example

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context), do: actor.permissions

        @impl true
        def load_actor(id) do
          case MyApp.Accounts.get_user(id) do
            nil -> :error
            user -> {:ok, user}
          end
        end
      end

  """
  @callback load_actor(id :: term()) :: {:ok, actor()} | :error

  @doc """
  Optional. Returns a second permission list that caps what `resolve/2` grants.

  Effective access is the intersection of the two lists: an action, a row, or a
  field group is authorized only when both lists authorize it, and a deny in
  either list wins. A ceiling can narrow the actor's grants but never widen them.

  The typical ceiling is the permission list of an API key, which must never
  grant more than its owner currently holds. Checking that at key creation is
  not enough, because the owner's roles change later.

  Takes the same arguments as `resolve/2`. Return `nil` for no ceiling, which
  leaves `resolve/2`'s grants as the only source. Return `[]` to deny
  everything. Any other return raises `ArgumentError`. A resolver that does not
  implement this callback has no ceiling, and neither does a function resolver.

  ## Example

  An `AshAuthentication` API-key sign-in puts the key on the user's metadata:

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(user, _context), do: MyApp.Accounts.permissions_for(user)

        @impl true
        def ceiling(%{__metadata__: %{api_key: api_key}}, _context), do: api_key.permissions
        def ceiling(_user, _context), do: nil
      end

  """
  @callback ceiling(actor(), context()) :: [permission()] | nil

  @optional_callbacks load_actor: 1, ceiling: 2
end

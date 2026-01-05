defprotocol AshGrant.Permissionable do
  @moduledoc """
  Protocol for converting values to `AshGrant.PermissionInput` structs.

  This protocol enables AshGrant to accept permissions from various sources
  without requiring manual conversion in your `PermissionResolver`.

  ## Why Use This Protocol?

  - **Zero boilerplate**: Return your existing structs directly from the resolver
  - **Separation of concerns**: Conversion logic lives near your struct definition
  - **Extensible**: Implement for any struct, including third-party ones
  - **Backward compatible**: Plain strings continue to work without changes

  ## Default Implementations

  AshGrant provides implementations for:

  - `BitString` (plain strings) - Converts to `PermissionInput` with just the string
  - `AshGrant.PermissionInput` - Pass-through, returns as-is
  - `AshGrant.Permission` - Converts parsed permission back to input format

  ## Implementing for Custom Structs

  If you have your own permission struct, implement the protocol:

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

  Then your resolver can simply return these structs:

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          # Just return your structs - AshGrant handles conversion
          MyApp.Accounts.get_role_permissions(actor)
        end
      end

  ## Usage Examples

  ### Plain strings (backward compatible)

      def resolve(actor, _context) do
        ["post:*:read:all", "post:*:update:own"]
      end

  ### Mixed strings and PermissionInput

      def resolve(actor, _context) do
        [
          "post:*:read:all",
          %AshGrant.PermissionInput{
            string: "post:*:update:own",
            description: "Edit own posts",
            source: "editor_role"
          }
        ]
      end

  ### Custom structs via Protocol

      def resolve(actor, _context) do
        # Returns [%MyApp.RolePermission{}, ...]
        # Protocol handles conversion automatically
        MyApp.Accounts.get_role_permissions(actor)
      end

  """

  @doc """
  Converts a value to `AshGrant.PermissionInput` struct.

  ## Examples

      iex> AshGrant.Permissionable.to_permission_input("post:*:read:all")
      %AshGrant.PermissionInput{string: "post:*:read:all"}

      iex> input = %AshGrant.PermissionInput{string: "post:*:read:all", description: "Read posts"}
      iex> AshGrant.Permissionable.to_permission_input(input)
      %AshGrant.PermissionInput{string: "post:*:read:all", description: "Read posts"}

  """
  @spec to_permission_input(t) :: AshGrant.PermissionInput.t()
  def to_permission_input(value)
end

# Default implementation for strings (backward compatibility)
defimpl AshGrant.Permissionable, for: BitString do
  def to_permission_input(string) do
    %AshGrant.PermissionInput{string: string}
  end
end

# Pass-through for PermissionInput struct
defimpl AshGrant.Permissionable, for: AshGrant.PermissionInput do
  def to_permission_input(input), do: input
end

# Convert parsed Permission back to PermissionInput
defimpl AshGrant.Permissionable, for: AshGrant.Permission do
  def to_permission_input(permission) do
    %AshGrant.PermissionInput{
      string: AshGrant.Permission.to_string(permission)
    }
  end
end

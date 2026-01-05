defmodule AshGrant.PermissionInput do
  @moduledoc """
  Permission input struct with optional metadata for debugging and explain functionality.

  This struct allows users to provide permissions with additional context
  like descriptions and source information, which can be used for:

  - Better debugging with `AshGrant.explain/4`
  - Understanding permission origins (role-based, direct grants, etc.)
  - Human-readable permission explanations

  ## Fields

  - `:string` - Required. The permission string (e.g., "post:*:update:own")
  - `:description` - Optional. Human-readable description (e.g., "Edit own posts")
  - `:source` - Optional. Where the permission came from (e.g., "editor_role", "direct_grant")
  - `:metadata` - Optional. Additional arbitrary metadata as a map

  ## Examples

      # Simple permission with just the string
      %AshGrant.PermissionInput{string: "post:*:read:all"}

      # Permission with metadata
      %AshGrant.PermissionInput{
        string: "post:*:update:own",
        description: "Edit own posts",
        source: "editor_role"
      }

      # Permission with extra metadata
      %AshGrant.PermissionInput{
        string: "post:*:delete:all",
        description: "Delete any post",
        source: "admin_role",
        metadata: %{granted_at: ~U[2024-01-15 10:00:00Z], granted_by: "system"}
      }

  ## Usage with PermissionResolver

  Return `PermissionInput` structs from your resolver for enhanced debugging:

      defmodule MyApp.PermissionResolver do
        @behaviour AshGrant.PermissionResolver

        @impl true
        def resolve(actor, _context) do
          actor
          |> get_role_permissions()
          |> Enum.map(fn role_perm ->
            %AshGrant.PermissionInput{
              string: role_perm.permission,
              description: role_perm.label,
              source: "role:\#{role_perm.role_name}"
            }
          end)
        end
      end

  ## Protocol Integration

  This struct implements `AshGrant.Permissionable`, so it can be used
  directly in permission lists without manual conversion.
  """

  @type t :: %__MODULE__{
          string: String.t(),
          description: String.t() | nil,
          source: String.t() | nil,
          metadata: map() | nil
        }

  @enforce_keys [:string]
  defstruct [:string, :description, :source, :metadata]

  @doc """
  Creates a new PermissionInput from a permission string.

  ## Examples

      iex> AshGrant.PermissionInput.new("post:*:read:all")
      %AshGrant.PermissionInput{string: "post:*:read:all"}

      iex> AshGrant.PermissionInput.new("post:*:update:own", description: "Edit own posts")
      %AshGrant.PermissionInput{string: "post:*:update:own", description: "Edit own posts"}

  """
  @spec new(String.t(), keyword()) :: t()
  def new(string, opts \\ []) when is_binary(string) do
    %__MODULE__{
      string: string,
      description: Keyword.get(opts, :description),
      source: Keyword.get(opts, :source),
      metadata: Keyword.get(opts, :metadata)
    }
  end

  @doc """
  Returns the permission string from a PermissionInput.

  ## Examples

      iex> input = %AshGrant.PermissionInput{string: "post:*:read:all", description: "Read posts"}
      iex> AshGrant.PermissionInput.to_string(input)
      "post:*:read:all"

  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{string: string}), do: string
end

defimpl String.Chars, for: AshGrant.PermissionInput do
  def to_string(input) do
    AshGrant.PermissionInput.to_string(input)
  end
end

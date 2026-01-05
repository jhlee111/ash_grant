defmodule AshGrant.Permission do
  @moduledoc """
  Permission struct with parsing and matching capabilities.

  This module provides the core permission representation for AshGrant.
  Permissions follow an Apache Shiro-inspired string format with a unified
  four-part syntax that handles both role-based (RBAC) and instance-level access.

  ## Permission Struct

  A permission consists of:

  - `resource` - The resource type (e.g., "blog", "post") or `"*"` for all
  - `instance_id` - The specific resource ID or `"*"` for all instances
  - `action` - The action (e.g., "read", "update") or wildcard patterns
  - `scope` - The access scope (e.g., "all", "own") for filtering
  - `deny` - Whether this is a deny rule (takes precedence over allow)

  ## Permission Format

  All permissions use a unified four-part format:

      [!]resource:instance_id:action:scope

  | Component | Description | Valid Values |
  |-----------|-------------|--------------|
  | `!` | Deny prefix (optional) | `!` or omitted |
  | resource | Resource type | identifier, `*` |
  | instance_id | Resource instance or `*` | prefixed_id, UUID, `*` |
  | action | Action name | identifier, `*`, `prefix*` |
  | scope | Access scope | `all`, `own`, custom, or empty |

  ## Wildcard Patterns

  **Resource wildcards:**
  - `*` - Matches any resource type

  **Instance wildcards:**
  - `*` - Matches any instance (RBAC-style permission)
  - `post_abc123xyz789ab` - Matches specific instance only

  **Action wildcards:**
  - `*` - Matches any action
  - `read*` - Matches `read`, `read_all`, `read_published`, etc.

  ## Examples

  ### RBAC Permissions (instance_id = "*")

      "blog:*:read:all"            # Read all blogs
      "blog:*:read:published"      # Read only published blogs
      "blog:*:update:own"          # Update own blogs only
      "blog:*:*:all"               # All actions on all blogs
      "*:*:read:all"               # Read all resources
      "*:*:*:all"                  # Full access to everything
      "blog:*:read*:all"           # All read-type actions
      "!blog:*:delete:all"         # DENY delete on all blogs

  ### Instance Permissions (specific instance_id)

  For sharing specific resource instances (like Google Docs sharing):

      "blog:post_abc123xyz789ab:read:"       # Read specific post (no conditions)
      "blog:post_abc123xyz789ab:*:"          # Full access to specific post
      "!blog:post_abc123xyz789ab:delete:"    # DENY delete on specific post

  ### Instance Permissions with Scopes (ABAC)

  Instance permissions can also include scopes for attribute-based conditions:

      "doc:doc_123:update:draft"             # Update only when document is in draft
      "doc:doc_123:read:business_hours"      # Read only during business hours
      "invoice:inv_456:approve:small_amount" # Approve only if amount is small
      "project:proj_789:admin:owner"         # Admin access only when owner

  When a scope is provided on an instance permission, it acts as an authorization
  condition that must be satisfied. Empty scopes (trailing colon) mean "no conditions"
  and are backward compatible with earlier versions.

  ## Backward Compatibility

  The parser also accepts shorter formats for convenience:

  - Two-part: `resource:action` → `resource:*:action:`
  - Three-part: `resource:action:scope` → `resource:*:action:scope`

  ## Usage

      # Parse from string (new format)
      {:ok, perm} = AshGrant.Permission.parse("blog:*:read:all")

      # Legacy format also works
      {:ok, perm} = AshGrant.Permission.parse("blog:read:all")

      # Parse with error on failure
      perm = AshGrant.Permission.parse!("blog:*:read:all")

      # Check if permission matches for RBAC
      AshGrant.Permission.matches?(perm, "blog", "read")
      # => true

      # Check instance permissions
      inst_perm = AshGrant.Permission.parse!("blog:post_abc123:read:")
      AshGrant.Permission.matches_instance?(inst_perm, "post_abc123", "read")
      # => true

      # Convert back to string
      AshGrant.Permission.to_string(perm)
      # => "blog:*:read:all"
  """

  @type t :: %__MODULE__{
          resource: String.t(),
          instance_id: String.t(),
          action: String.t(),
          scope: String.t() | nil,
          deny: boolean(),
          # Metadata fields (optional, for debugging/explain)
          description: String.t() | nil,
          source: String.t() | nil,
          metadata: map() | nil
        }

  defstruct [
    :resource,
    :action,
    :scope,
    :description,
    :source,
    :metadata,
    instance_id: "*",
    deny: false
  ]

  @doc """
  Parses a permission string into a Permission struct.

  Supports both the new four-part format and legacy formats for backward compatibility.

  ## New Format (preferred)

      "resource:instance_id:action:scope"

  ## Legacy Formats (still supported)

      "resource:action:scope"  →  resource:*:action:scope
      "resource:action"        →  resource:*:action:

  ## Examples

      iex> AshGrant.Permission.parse("blog:*:read:all")
      {:ok, %AshGrant.Permission{resource: "blog", instance_id: "*", action: "read", scope: "all", deny: false}}

      iex> AshGrant.Permission.parse("blog:post_abc123xyz789ab:read:")
      {:ok, %AshGrant.Permission{resource: "blog", instance_id: "post_abc123xyz789ab", action: "read", scope: nil, deny: false}}

      iex> AshGrant.Permission.parse("!blog:*:delete:all")
      {:ok, %AshGrant.Permission{resource: "blog", instance_id: "*", action: "delete", scope: "all", deny: true}}

      # Legacy format
      iex> AshGrant.Permission.parse("blog:read:all")
      {:ok, %AshGrant.Permission{resource: "blog", instance_id: "*", action: "read", scope: "all", deny: false}}

  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(permission_string) when is_binary(permission_string) do
    {deny, rest} = parse_deny_prefix(permission_string)

    case String.split(rest, ":") do
      # New four-part format: resource:instance_id:action:scope
      [resource, instance_id, action, scope] ->
        {:ok,
         %__MODULE__{
           resource: resource,
           instance_id: instance_id,
           action: action,
           scope: normalize_scope(scope),
           deny: deny
         }}

      # Legacy three-part format: resource:action:scope
      # Convert to: resource:*:action:scope
      [resource, action, scope] ->
        {:ok,
         %__MODULE__{
           resource: resource,
           instance_id: "*",
           action: action,
           scope: normalize_scope(scope),
           deny: deny
         }}

      # Legacy two-part format: resource:action
      # Convert to: resource:*:action:
      [resource, action] ->
        {:ok,
         %__MODULE__{
           resource: resource,
           instance_id: "*",
           action: action,
           scope: nil,
           deny: deny
         }}

      _ ->
        {:error, "Invalid permission format: #{permission_string}"}
    end
  end

  def parse(permission) when is_map(permission) do
    # Ensure instance_id defaults to "*" for maps
    permission = Map.put_new(permission, :instance_id, "*")
    {:ok, struct(__MODULE__, permission)}
  end

  @doc """
  Parses a permission string, raising on error.
  """
  @spec parse!(String.t()) :: t()
  def parse!(permission_string) do
    case parse(permission_string) do
      {:ok, permission} -> permission
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Creates a Permission struct from a PermissionInput, preserving metadata.

  This function parses the permission string from the input and copies
  over the metadata fields (description, source, metadata).

  ## Examples

      iex> input = %AshGrant.PermissionInput{
      ...>   string: "blog:*:read:all",
      ...>   description: "Read all blogs",
      ...>   source: "editor_role"
      ...> }
      iex> AshGrant.Permission.from_input(input)
      %AshGrant.Permission{
        resource: "blog",
        instance_id: "*",
        action: "read",
        scope: "all",
        deny: false,
        description: "Read all blogs",
        source: "editor_role",
        metadata: nil
      }

  """
  @spec from_input(AshGrant.PermissionInput.t()) :: t()
  def from_input(%AshGrant.PermissionInput{} = input) do
    permission = parse!(input.string)

    %{
      permission
      | description: input.description,
        source: input.source,
        metadata: input.metadata
    }
  end

  @doc """
  Converts a Permission struct back to string format.

  Always uses the new four-part format.

  ## Examples

      iex> perm = %AshGrant.Permission{resource: "blog", instance_id: "*", action: "read", scope: "all"}
      iex> AshGrant.Permission.to_string(perm)
      "blog:*:read:all"

      iex> perm = %AshGrant.Permission{resource: "blog", instance_id: "post_abc123", action: "read", scope: nil}
      iex> AshGrant.Permission.to_string(perm)
      "blog:post_abc123:read:"

      iex> perm = %AshGrant.Permission{resource: "blog", instance_id: "*", action: "delete", scope: "all", deny: true}
      iex> AshGrant.Permission.to_string(perm)
      "!blog:*:delete:all"

  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = perm) do
    prefix = if perm.deny, do: "!", else: ""
    scope = perm.scope || ""
    instance_id = perm.instance_id || "*"

    "#{prefix}#{perm.resource}:#{instance_id}:#{perm.action}:#{scope}"
  end

  @doc """
  Checks if a permission matches a resource and action.

  This only matches RBAC-style permissions (where instance_id is "*").
  For instance-level matching, use `matches_instance?/3`.

  Does not consider scope - that's handled by the ScopeResolver.

  ## Examples

      iex> perm = AshGrant.Permission.parse!("blog:*:read:all")
      iex> AshGrant.Permission.matches?(perm, "blog", "read")
      true

      iex> perm = AshGrant.Permission.parse!("blog:*:read*:all")
      iex> AshGrant.Permission.matches?(perm, "blog", "read_published")
      true

      iex> perm = AshGrant.Permission.parse!("blog:*:*:all")
      iex> AshGrant.Permission.matches?(perm, "blog", "delete")
      true

  """
  @spec matches?(t(), String.t(), String.t()) :: boolean()
  def matches?(%__MODULE__{instance_id: "*"} = perm, resource, action) do
    matches_resource?(perm.resource, resource) and
      matches_action?(perm.action, action)
  end

  def matches?(%__MODULE__{}, _resource, _action) do
    # Instance-level permissions don't match RBAC queries
    false
  end

  @doc """
  Checks if a permission matches a specific resource instance.

  ## Examples

      iex> perm = AshGrant.Permission.parse!("blog:post_abc123xyz789ab:read:")
      iex> AshGrant.Permission.matches_instance?(perm, "post_abc123xyz789ab", "read")
      true

      iex> perm = AshGrant.Permission.parse!("blog:post_abc123xyz789ab:*:")
      iex> AshGrant.Permission.matches_instance?(perm, "post_abc123xyz789ab", "write")
      true

  """
  @spec matches_instance?(t(), String.t(), String.t()) :: boolean()
  def matches_instance?(%__MODULE__{instance_id: "*"}, _instance_id, _action) do
    # RBAC permissions don't match instance queries
    false
  end

  def matches_instance?(%__MODULE__{} = perm, instance_id, action) do
    perm.instance_id == instance_id and matches_action?(perm.action, action)
  end

  @doc """
  Checks if this is an instance-level permission.

  An instance permission has a specific instance_id (not "*").
  """
  @spec instance_permission?(t()) :: boolean()
  def instance_permission?(%__MODULE__{instance_id: "*"}), do: false
  def instance_permission?(%__MODULE__{}), do: true

  @doc """
  Checks if this is a deny rule.
  """
  @spec deny?(t()) :: boolean()
  def deny?(%__MODULE__{deny: deny}), do: deny

  @doc """
  Returns the resource type from this permission.
  """
  @spec resource(t()) :: String.t()
  def resource(%__MODULE__{resource: resource}), do: resource

  @doc """
  Checks if a resource pattern matches a resource name.

  Supports wildcard matching with `"*"`.

  ## Examples

      iex> AshGrant.Permission.matches_resource?("*", "blog")
      true
      iex> AshGrant.Permission.matches_resource?("blog", "blog")
      true
      iex> AshGrant.Permission.matches_resource?("blog", "post")
      false

  """
  @spec matches_resource?(String.t(), String.t()) :: boolean()
  def matches_resource?("*", _resource), do: true
  def matches_resource?(pattern, pattern), do: true
  def matches_resource?(_pattern, _resource), do: false

  @doc """
  Checks if an action pattern matches an action name.

  Supports wildcard matching with `"*"` and prefix matching with `"prefix*"`.

  ## Examples

      iex> AshGrant.Permission.matches_action?("*", "read")
      true
      iex> AshGrant.Permission.matches_action?("read", "read")
      true
      iex> AshGrant.Permission.matches_action?("read*", "read_all")
      true
      iex> AshGrant.Permission.matches_action?("read", "write")
      false

  """
  @spec matches_action?(String.t(), String.t()) :: boolean()
  def matches_action?("*", _action), do: true

  def matches_action?(pattern, action) do
    if String.ends_with?(pattern, "*") do
      prefix = String.trim_trailing(pattern, "*")
      String.starts_with?(action, prefix)
    else
      pattern == action
    end
  end

  # Private functions

  defp parse_deny_prefix("!" <> rest), do: {true, rest}
  defp parse_deny_prefix(str), do: {false, str}

  defp normalize_scope(""), do: nil
  defp normalize_scope(scope), do: scope
end

defimpl String.Chars, for: AshGrant.Permission do
  def to_string(permission) do
    AshGrant.Permission.to_string(permission)
  end
end

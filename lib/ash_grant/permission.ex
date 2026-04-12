defmodule AshGrant.Permission do
  @moduledoc """
  Permission struct with parsing and matching capabilities.

  This module provides the core permission representation for AshGrant.
  Permissions follow an Apache Shiro-inspired string format that handles both
  role-based (RBAC) and instance-level access, with an optional field group
  for column-level restrictions.

  ## Permission Struct

  A permission consists of:

  - `resource` - The resource type (e.g., "blog", "post") or `"*"` for all
  - `instance_id` - The specific resource ID or `"*"` for all instances
  - `action` - The action (e.g., "read", "update") or wildcard patterns
  - `scope` - The access scope (e.g., "always", "own") for filtering
  - `field_group` - Optional field group for column-level access (e.g., "sensitive")
  - `deny` - Whether this is a deny rule (takes precedence over allow)

  ## Permission Format

      [!]resource:instance_id:action:scope[:field_group]

  | Component | Description | Valid Values |
  |-----------|-------------|--------------|
  | `!` | Deny prefix (optional) | `!` or omitted |
  | resource | Resource type | identifier, `*` |
  | instance_id | Resource instance or `*` | prefixed_id, UUID, `*` |
  | action | Action name | identifier, `*`, `prefix*` |
  | scope | Access scope | `all`, `own`, custom, or empty |
  | field_group | Column-level group (optional) | `public`, `sensitive`, custom |

  ## Wildcard Patterns

  **Resource wildcards:**
  - `*` - Matches any resource type

  **Instance wildcards:**
  - `*` - Matches any instance (RBAC-style permission)
  - `post_abc123xyz789ab` - Matches specific instance only

  **Action wildcards:**
  - `*` - Matches any action
  - `read*` - Matches any action whose type is `:read` (requires action_type)

  ## Examples

  ### RBAC Permissions (instance_id = "*")

      "blog:*:read:always"            # Read all blogs
      "blog:*:read:published"      # Read only published blogs
      "blog:*:update:own"          # Update own blogs only
      "blog:*:*:always"               # All actions on all blogs
      "*:*:read:always"               # Read all resources
      "*:*:*:always"                  # Full access to everything
      "blog:*:read*:always"           # All read-type actions
      "!blog:*:delete:always"         # DENY delete on all blogs

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
      {:ok, perm} = AshGrant.Permission.parse("blog:*:read:always")

      # Legacy format also works
      {:ok, perm} = AshGrant.Permission.parse("blog:read:always")

      # Parse with error on failure
      perm = AshGrant.Permission.parse!("blog:*:read:always")

      # Check if permission matches for RBAC
      AshGrant.Permission.matches?(perm, "blog", "read")
      # => true

      # Check instance permissions
      inst_perm = AshGrant.Permission.parse!("blog:post_abc123:read:")
      AshGrant.Permission.matches_instance?(inst_perm, "post_abc123", "read")
      # => true

      # Convert back to string
      AshGrant.Permission.to_string(perm)
      # => "blog:*:read:always"
  """

  @type t :: %__MODULE__{
          resource: String.t(),
          instance_id: String.t(),
          action: String.t(),
          scope: String.t() | nil,
          field_group: String.t() | nil,
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
    :field_group,
    :description,
    :source,
    :metadata,
    instance_id: "*",
    deny: false
  ]

  @doc """
  Parses a permission string into a Permission struct.

  Supports 4-part, 5-part (with field_group), and legacy formats.

  ## Formats

      "resource:instance_id:action:scope"                # 4-part
      "resource:instance_id:action:scope:field_group"    # 5-part (with field group)
      "resource:action:scope"                            # Legacy 3-part → resource:*:action:scope
      "resource:action"                                  # Legacy 2-part → resource:*:action:

  ## Examples

      iex> AshGrant.Permission.parse("blog:*:read:always")
      {:ok, %AshGrant.Permission{resource: "blog", instance_id: "*", action: "read", scope: "always", deny: false}}

      iex> AshGrant.Permission.parse("employee:*:read:always:sensitive")
      {:ok, %AshGrant.Permission{resource: "employee", instance_id: "*", action: "read", scope: "always", field_group: "sensitive", deny: false}}

      iex> AshGrant.Permission.parse("!blog:*:delete:always")
      {:ok, %AshGrant.Permission{resource: "blog", instance_id: "*", action: "delete", scope: "always", deny: true}}

      iex> AshGrant.Permission.parse("blog:post_abc123xyz789ab:read:")
      {:ok, %AshGrant.Permission{resource: "blog", instance_id: "post_abc123xyz789ab", action: "read", scope: nil, deny: false}}

  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(permission_string) when is_binary(permission_string) do
    {deny, rest} = parse_deny_prefix(permission_string)

    case String.split(rest, ":") do
      # Five-part format: resource:instance_id:action:scope:field_group
      [resource, instance_id, action, scope, field_group] ->
        {:ok,
         %__MODULE__{
           resource: resource,
           instance_id: instance_id,
           action: action,
           scope: normalize_scope(scope),
           field_group: normalize_field_group(field_group),
           deny: deny
         }}

      # Four-part format: resource:instance_id:action:scope
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
        maybe_warn_ambiguous_format(permission_string, resource, action, scope)

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
      ...>   string: "blog:*:read:always",
      ...>   description: "Read all blogs",
      ...>   source: "editor_role"
      ...> }
      iex> AshGrant.Permission.from_input(input)
      %AshGrant.Permission{
        resource: "blog",
        instance_id: "*",
        action: "read",
        scope: "always",
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

  Produces a 4-part string, or 5-part when `field_group` is set.

  ## Examples

      iex> perm = %AshGrant.Permission{resource: "blog", instance_id: "*", action: "read", scope: "always"}
      iex> AshGrant.Permission.to_string(perm)
      "blog:*:read:always"

      iex> perm = %AshGrant.Permission{resource: "employee", instance_id: "*", action: "read", scope: "always", field_group: "sensitive"}
      iex> AshGrant.Permission.to_string(perm)
      "employee:*:read:always:sensitive"

      iex> perm = %AshGrant.Permission{resource: "blog", instance_id: "*", action: "delete", scope: "always", deny: true}
      iex> AshGrant.Permission.to_string(perm)
      "!blog:*:delete:always"

  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = perm) do
    prefix = if perm.deny, do: "!", else: ""
    scope = perm.scope || ""
    instance_id = perm.instance_id || "*"
    base = "#{prefix}#{perm.resource}:#{instance_id}:#{perm.action}:#{scope}"

    case perm.field_group do
      nil -> base
      fg -> "#{base}:#{fg}"
    end
  end

  @doc """
  Checks if a permission matches a resource and action.

  This only matches RBAC-style permissions (where instance_id is "*").
  For instance-level matching, use `matches_instance?/3`.

  Does not consider scope - that's handled by the ScopeResolver.

  ## Examples

      iex> perm = AshGrant.Permission.parse!("blog:*:read:always")
      iex> AshGrant.Permission.matches?(perm, "blog", "read")
      true

      iex> perm = AshGrant.Permission.parse!("blog:*:read*:always")
      iex> AshGrant.Permission.matches?(perm, "blog", "read_published")
      false

      iex> perm = AshGrant.Permission.parse!("blog:*:*:always")
      iex> AshGrant.Permission.matches?(perm, "blog", "delete")
      true

  """
  @spec matches?(t(), String.t(), String.t()) :: boolean()
  def matches?(perm, resource, action), do: matches?(perm, resource, action, nil)

  @doc """
  Checks if a permission matches a resource, action, and optional Ash action type.

  When `action_type` is provided, prefix patterns like `"read*"` will also match
  actions whose Ash type equals the prefix (e.g., a `:read`-type action named
  `list_published` matches `"read*"`).

  ## Examples

      iex> perm = AshGrant.Permission.parse!("blog:*:read*:always")
      iex> AshGrant.Permission.matches?(perm, "blog", "list_published", :read)
      true

      iex> perm = AshGrant.Permission.parse!("blog:*:read*:always")
      iex> AshGrant.Permission.matches?(perm, "blog", "list_published", :update)
      false

  """
  @spec matches?(t(), String.t(), String.t(), atom() | nil) :: boolean()
  def matches?(%__MODULE__{instance_id: "*"} = perm, resource, action, action_type) do
    matches_resource?(perm.resource, resource) and
      matches_action?(perm.action, action, action_type)
  end

  def matches?(%__MODULE__{}, _resource, _action, _action_type) do
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
      false
      iex> AshGrant.Permission.matches_action?("read", "write")
      false

  """
  @spec matches_action?(String.t(), String.t()) :: boolean()
  def matches_action?(pattern, action), do: matches_action?(pattern, action, nil)

  @doc """
  Checks if an action pattern matches an action name, with optional Ash action type.

  When `action_type` is provided and the pattern is a type wildcard like `"read*"`,
  the match succeeds if the action type matches the prefix. This allows `"read*"` to
  match `:read`-type actions like `list_published` or `by_slug`. Without `action_type`,
  type wildcards never match — use exact action names instead.

  ## Examples

      iex> AshGrant.Permission.matches_action?("*", "anything", :read)
      true
      iex> AshGrant.Permission.matches_action?("read*", "list_published", :read)
      true
      iex> AshGrant.Permission.matches_action?("read*", "list_published", :update)
      false
      iex> AshGrant.Permission.matches_action?("read*", "read_all", nil)
      false
      iex> AshGrant.Permission.matches_action?("update*", "publish", :update)
      true
      iex> AshGrant.Permission.matches_action?("read", "read", :read)
      true

  """
  @spec matches_action?(String.t(), String.t(), atom() | nil) :: boolean()
  def matches_action?("*", _action, _action_type), do: true

  def matches_action?(pattern, action, action_type) do
    if String.ends_with?(pattern, "*") do
      prefix = String.trim_trailing(pattern, "*")
      action_type != nil and Atom.to_string(action_type) == prefix
    else
      pattern == action
    end
  end

  # Private functions

  defp parse_deny_prefix("!" <> rest), do: {true, rest}
  defp parse_deny_prefix(str), do: {false, str}

  defp normalize_scope(""), do: nil
  defp normalize_scope(scope), do: scope

  defp normalize_field_group(""), do: nil
  defp normalize_field_group(fg), do: fg

  # Warns when a 3-part permission format might be ambiguous.
  # For example, "blog:post123:read" could be mistaken for an instance permission
  # but is parsed as "blog:*:post123:read" (with post123 as the action).
  defp maybe_warn_ambiguous_format(original, resource, action, scope) do
    if looks_like_instance_id?(action) do
      IO.warn(
        """
        Ambiguous permission format: "#{original}"

        This is parsed as: #{resource}:*:#{action}:#{scope}
        If you meant an instance permission, use the 4-part format: #{resource}:#{action}:<action>:

        Consider using the explicit 4-part format to avoid ambiguity.
        See: https://github.com/jhlee111/ash_grant#legacy-format-support
        """,
        []
      )
    end
  end

  # Checks if a string looks like an instance ID rather than an action name.
  # Instance IDs typically have formats like:
  # - Prefixed IDs: post_abc123, doc_xyz789
  # - UUIDs: 550e8400-e29b-41d4-a716-446655440000
  # - Numeric IDs: 12345
  defp looks_like_instance_id?(str) do
    cond do
      # Prefixed ID pattern: prefix_alphanumeric (e.g., post_abc123)
      Regex.match?(~r/^[a-z]+_[a-z0-9]+$/i, str) -> true
      # UUID pattern (partial match for first segment)
      Regex.match?(~r/^[0-9a-f]{8}-/i, str) -> true
      # Pure numeric ID
      Regex.match?(~r/^\d+$/, str) -> true
      # Default: assume it's an action name
      true -> false
    end
  end
end

defimpl String.Chars, for: AshGrant.Permission do
  def to_string(permission) do
    AshGrant.Permission.to_string(permission)
  end
end

defmodule AshGrant.Evaluator do
  @moduledoc """
  Permission evaluation with deny-wins semantics.

  This module evaluates a list of permissions against a resource and action,
  implementing the deny-wins pattern where any deny rule takes precedence
  over allow rules. It is the core evaluation engine used by `AshGrant.Check`
  and `AshGrant.FilterCheck`.

  ## Deny-Wins Pattern

  The evaluation follows these rules:

  1. If **ANY** deny rule matches → access **denied**
  2. If **NO** deny rule matches AND at least one allow rule matches → access **granted**
  3. If **no rules** match → access **denied**

  This is similar to Apache Shiro's authorization model and provides a secure
  default (deny by default) with the ability to revoke permissions at any level.

  ## Why Deny-Wins?

  The deny-wins pattern is useful for:

  - **Revoking permissions**: Easily revoke specific permissions from broad grants
  - **Exception handling**: "Allow all except X" patterns
  - **Inheritance overrides**: Child roles can restrict parent permissions
  - **Security**: Explicit denials cannot be accidentally overridden

  ## Permission Input Formats

  The evaluator accepts permissions in multiple formats:

  - **Strings**: `"blog:*:read:always"`, `"!blog:*:delete:always"`, `"employee:*:read:always:sensitive"` (5-part)
  - **Permission structs**: `%AshGrant.Permission{...}`
  - **PermissionInput structs**: `%AshGrant.PermissionInput{string: "blog:*:read:always", ...}`
  - **Custom structs**: Any struct implementing the `AshGrant.Permissionable` protocol

  All formats are automatically normalized internally.

  ## Examples

  ### Basic Access Check

      permissions = ["blog:*:read:always", "blog:*:write:own"]

      Evaluator.has_access?(permissions, "blog", "read")   # true
      Evaluator.has_access?(permissions, "blog", "write")  # true
      Evaluator.has_access?(permissions, "blog", "delete") # false

  ### Deny-Wins in Action

      permissions = [
        "blog:*:*:always",           # Allow all blog actions
        "!blog:*:delete:always"      # Deny delete
      ]

      Evaluator.has_access?(permissions, "blog", "read")   # true
      Evaluator.has_access?(permissions, "blog", "update") # true
      Evaluator.has_access?(permissions, "blog", "delete") # false (deny wins!)

  ### Getting Scopes

      permissions = [
        "blog:*:read:own",
        "blog:*:read:published",
        "blog:*:update:own"
      ]

      Evaluator.get_scope(permissions, "blog", "read")
      # => "own" (first matching)

      Evaluator.get_all_scopes(permissions, "blog", "read")
      # => ["own", "published"]

  ### Instance Permissions

      # Instance permission format: resource:instance_id:action:
      permissions = ["feed:feed_abc123xyz789ab:read:", "feed:feed_abc123xyz789ab:write:"]

      Evaluator.has_instance_access?(permissions, "feed_abc123xyz789ab", "read")
      # => true

  ### Instance Permissions with Scopes (ABAC)

  Instance permissions can include scope conditions for attribute-based access:

      # Instance permission with scope: resource:instance_id:action:scope
      permissions = ["doc:doc_123:update:draft", "doc:doc_123:read:business_hours"]

      # Check if access is granted
      Evaluator.has_instance_access?(permissions, "doc_123", "update")
      # => true

      # Get the scope condition for further evaluation
      Evaluator.get_instance_scope(permissions, "doc_123", "update")
      # => "draft" (the application can then verify if the document is in draft status)

      # Get all scopes for an action
      Evaluator.get_all_instance_scopes(permissions, "doc_123", "read")
      # => ["business_hours"]

  ## Functions Overview

  | Function | Purpose |
  |----------|---------|
  | `has_access?/3` | Check if actor can perform action on resource type |
  | `has_instance_access?/3` | Check if actor can perform action on specific instance |
  | `get_scope/3` | Get first matching scope (for SimpleCheck) |
  | `get_all_scopes/3` | Get all matching scopes (for FilterCheck) |
  | `get_field_group/3` | Get first matching field group from 5-part permissions |
  | `get_all_field_groups/3` | Get all matching field groups (union for field access) |
  | `get_instance_scope/3` | Get scope from instance permission (for ABAC conditions) |
  | `get_all_instance_scopes/3` | Get all scopes from instance permissions |
  | `get_matching_instance_ids/3` | Get all instance IDs for a resource/action |
  | `find_matching/3` | Get all matching permissions (debug/introspection) |
  | `combine/1` | Merge multiple permission lists |
  """

  alias AshGrant.Permission

  @type permissions :: [Permission.t() | String.t() | map()]

  @doc """
  Checks if the given permissions grant access to a resource and action.

  Implements deny-wins: if any deny rule matches, access is denied.

  ## Examples

      iex> permissions = ["blog:*:read:always", "blog:*:write:own"]
      iex> AshGrant.Evaluator.has_access?(permissions, "blog", "read")
      true

      iex> permissions = ["blog:*:*:always", "!blog:*:delete:always"]
      iex> AshGrant.Evaluator.has_access?(permissions, "blog", "delete")
      false

  """
  @spec has_access?(permissions(), String.t(), String.t(), atom() | nil) :: boolean()
  def has_access?(permissions, resource, action, action_type \\ nil) do
    permissions = normalize_permissions(permissions)

    # Check for deny rules first (deny wins)
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)

    if has_deny do
      false
    else
      # Check for allow rules
      Enum.any?(permissions, fn perm ->
        not Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)
    end
  end

  @doc """
  Checks if the given permissions grant access to a specific resource instance.

  Instance permissions use the format `resource:instance_id:action:scope` where
  the scope can be empty (backward compatible) or contain a scope condition.

  ## Examples

      iex> permissions = ["feed:feed_abc123xyz789ab:read:", "feed:feed_abc123xyz789ab:write:"]
      iex> AshGrant.Evaluator.has_instance_access?(permissions, "feed_abc123xyz789ab", "read")
      true

      iex> permissions = ["doc:doc_123:update:draft"]
      iex> AshGrant.Evaluator.has_instance_access?(permissions, "doc_123", "update")
      true

  """
  @spec has_instance_access?(permissions(), String.t(), String.t()) :: boolean()
  def has_instance_access?(permissions, instance_id, action) do
    permissions = normalize_permissions(permissions)

    # Check for deny rules first
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches_instance?(perm, instance_id, action)
      end)

    if has_deny do
      false
    else
      # Check for allow rules
      Enum.any?(permissions, fn perm ->
        not Permission.deny?(perm) and Permission.matches_instance?(perm, instance_id, action)
      end)
    end
  end

  @doc """
  Gets the scope for a matching instance permission.

  Returns the scope from the first matching allow permission for the given instance.
  Returns nil if no matching permission is found, if denied, or if the scope is empty.

  This enables ABAC-style conditions on instance permissions, where the scope
  represents an authorization condition (e.g., "draft", "business_hours", "small_amount").

  ## Examples

      iex> permissions = ["doc:doc_123:update:draft"]
      iex> AshGrant.Evaluator.get_instance_scope(permissions, "doc_123", "update")
      "draft"

      iex> permissions = ["doc:doc_123:read:"]
      iex> AshGrant.Evaluator.get_instance_scope(permissions, "doc_123", "read")
      nil

      iex> permissions = ["doc:doc_123:*:always", "!doc:doc_123:delete:always"]
      iex> AshGrant.Evaluator.get_instance_scope(permissions, "doc_123", "delete")
      nil

  """
  @spec get_instance_scope(permissions(), String.t(), String.t()) :: String.t() | nil
  def get_instance_scope(permissions, instance_id, action) do
    permissions = normalize_permissions(permissions)

    # Check for deny first
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches_instance?(perm, instance_id, action)
      end)

    if has_deny do
      nil
    else
      # Find first matching allow permission and return its scope
      permissions
      |> Enum.find(fn perm ->
        not Permission.deny?(perm) and Permission.matches_instance?(perm, instance_id, action)
      end)
      |> case do
        nil -> nil
        perm -> perm.scope
      end
    end
  end

  @doc """
  Gets all scopes for matching instance permissions.

  Returns a list of scopes from all matching allow permissions for the given instance.
  Useful when a user has multiple instance permissions with different scopes.

  ## Examples

      iex> permissions = ["doc:doc_123:read:draft", "doc:doc_123:read:internal"]
      iex> AshGrant.Evaluator.get_all_instance_scopes(permissions, "doc_123", "read")
      ["draft", "internal"]

      iex> permissions = ["doc:doc_123:*:always", "!doc:doc_123:delete:always"]
      iex> AshGrant.Evaluator.get_all_instance_scopes(permissions, "doc_123", "delete")
      []

  """
  @spec get_all_instance_scopes(permissions(), String.t(), String.t()) :: [String.t()]
  def get_all_instance_scopes(permissions, instance_id, action) do
    permissions = normalize_permissions(permissions)

    # Check for deny first
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches_instance?(perm, instance_id, action)
      end)

    if has_deny do
      []
    else
      permissions
      |> Enum.filter(fn perm ->
        not Permission.deny?(perm) and Permission.matches_instance?(perm, instance_id, action)
      end)
      |> Enum.map(& &1.scope)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end
  end

  @doc """
  Gets the scope for a matching permission.

  Returns the scope from the first matching allow permission.
  Returns nil if no matching permission is found or if the match is a deny.

  ## Examples

      iex> permissions = ["blog:*:read:always", "blog:*:update:own"]
      iex> AshGrant.Evaluator.get_scope(permissions, "blog", "read")
      "always"
      iex> AshGrant.Evaluator.get_scope(permissions, "blog", "update")
      "own"
      iex> AshGrant.Evaluator.get_scope(permissions, "blog", "delete")
      nil

  """
  @spec get_scope(permissions(), String.t(), String.t(), atom() | nil) :: String.t() | nil
  def get_scope(permissions, resource, action, action_type \\ nil) do
    permissions = normalize_permissions(permissions)

    # First check if denied
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)

    if has_deny do
      nil
    else
      # Find first matching allow permission and return its scope
      permissions
      |> Enum.find(fn perm ->
        not Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)
      |> case do
        nil -> nil
        perm -> perm.scope
      end
    end
  end

  @doc """
  Gets all scopes for matching permissions.

  Returns a list of scopes from all matching allow permissions.
  Useful when a user has multiple roles with different scopes.

  ## Examples

      iex> permissions = ["blog:*:read:own", "blog:*:read:published", "blog:*:read:always"]
      iex> AshGrant.Evaluator.get_all_scopes(permissions, "blog", "read")
      ["own", "published", "always"]

  """
  @spec get_all_scopes(permissions(), String.t(), String.t(), atom() | nil) :: [String.t()]
  def get_all_scopes(permissions, resource, action, action_type \\ nil) do
    permissions = normalize_permissions(permissions)

    # Check for deny first
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)

    if has_deny do
      []
    else
      permissions
      |> Enum.filter(fn perm ->
        not Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)
      |> Enum.map(& &1.scope)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end
  end

  @doc """
  Gets the field group from the first matching permission.

  Returns the field_group string from the first matching allow permission.
  Returns nil if no matching permission, if denied, or if no field_group is set.

  ## Examples

      iex> permissions = ["employee:*:read:always:sensitive"]
      iex> AshGrant.Evaluator.get_field_group(permissions, "employee", "read")
      "sensitive"

      iex> permissions = ["employee:*:read:always"]
      iex> AshGrant.Evaluator.get_field_group(permissions, "employee", "read")
      nil

  """
  @spec get_field_group(permissions(), String.t(), String.t(), atom() | nil) :: String.t() | nil
  def get_field_group(permissions, resource, action, action_type \\ nil) do
    permissions = normalize_permissions(permissions)

    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)

    if has_deny do
      nil
    else
      permissions
      |> Enum.find(fn perm ->
        not Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)
      |> case do
        nil -> nil
        perm -> perm.field_group
      end
    end
  end

  @doc """
  Gets all field groups from matching permissions.

  Returns a deduplicated list of field group names from all matching allow permissions.
  When an actor has multiple permissions with different field groups, these are merged
  as a union to determine the combined set of accessible fields.

  A matching group-less (4-part) allow grant means "all fields are visible". Since
  unrestricted access dominates the union (all fields ∪ anything = all fields), such a
  grant collapses the result to `[]` — the same "unrestricted" signal consumers use
  when there is no field restriction at all. A broader group-less grant is therefore
  never narrowed by a more specific field-group grant (additive allow semantics).

  ## Examples

      iex> permissions = ["employee:*:read:always:sensitive", "employee:*:read:always:billing"]
      iex> AshGrant.Evaluator.get_all_field_groups(permissions, "employee", "read")
      ["sensitive", "billing"]

      iex> permissions = ["employee:*:read:always", "employee:*:read:always:sensitive"]
      iex> AshGrant.Evaluator.get_all_field_groups(permissions, "employee", "read")
      []

      iex> permissions = ["employee:*:read:always:sensitive", "!employee:*:read:always"]
      iex> AshGrant.Evaluator.get_all_field_groups(permissions, "employee", "read")
      []

  """
  @spec get_all_field_groups(permissions(), String.t(), String.t(), atom() | nil) :: [String.t()]
  def get_all_field_groups(permissions, resource, action, action_type \\ nil) do
    permissions = normalize_permissions(permissions)

    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action, action_type)
      end)

    if has_deny do
      []
    else
      matching_allows =
        Enum.filter(permissions, fn perm ->
          not Permission.deny?(perm) and
            Permission.matches?(perm, resource, action, action_type)
        end)

      # A group-less (4-part) allow grant means "all fields are visible" and
      # dominates the union, so it collapses the result to [] (unrestricted).
      # Without this, adding a narrower field-group grant on top of a broad
      # group-less grant would silently subtract access (see issue #116).
      if Enum.any?(matching_allows, &is_nil(&1.field_group)) do
        []
      else
        matching_allows
        |> Enum.map(& &1.field_group)
        |> Enum.uniq()
      end
    end
  end

  @doc """
  Returns the ALLOW permissions that grant visibility of `required_group` on some
  rows, for per-record field-group authorization (issue #117 phase ②).

  Unlike `get_all_field_groups/4`, this INCLUDES instance permissions (whose
  field_group `get_all_field_groups` discards) and keeps each grant's `scope` and
  `instance_id` intact, so a per-record predicate can be built from the result
  (`AshGrant.FieldFilterCheck`).

  A permission contributes when it is an allow, matches the resource and action
  (for any `instance_id`), and either is group-less (4-part — grants every group)
  or its `field_group` equals or inherits toward `required_group`.

  `resource_module` is the resource module (needed to resolve field-group
  inheritance); `required_group` is the field-group atom.
  """
  @spec field_group_grants(permissions(), module(), String.t(), atom(), atom() | nil) ::
          [Permission.t()]
  def field_group_grants(permissions, resource_module, action, required_group, action_type \\ nil) do
    resource_name = AshGrant.Info.resource_name(resource_module)

    permissions
    |> normalize_permissions()
    |> Enum.filter(fn perm ->
      not Permission.deny?(perm) and
        Permission.matches_resource?(perm.resource, resource_name) and
        Permission.matches_action?(perm.action, action, action_type) and
        grants_field_group?(resource_module, perm.field_group, required_group)
    end)
  end

  # A group-less (4-part) grant has no field_group — it grants every group.
  defp grants_field_group?(_resource_module, nil, _required), do: true

  defp grants_field_group?(resource_module, field_group, required) when is_binary(field_group) do
    field_group == to_string(required) or
      field_group_inherits_toward?(resource_module, field_group, required)
  end

  defp field_group_inherits_toward?(resource_module, field_group, required) do
    group_atom = String.to_existing_atom(field_group)
    inherits_toward?(resource_module, group_atom, required)
  rescue
    # Unknown field-group string (e.g. a typo) cannot inherit toward anything.
    ArgumentError -> false
  end

  defp inherits_toward?(resource_module, group_atom, target) do
    case AshGrant.Info.get_field_group(resource_module, group_atom) do
      nil ->
        false

      fg ->
        parents = fg.inherits || []
        target in parents or Enum.any?(parents, &inherits_toward?(resource_module, &1, target))
    end
  end

  @doc """
  Finds all matching permissions (both allow and deny).

  ## Examples

      iex> permissions = ["blog:*:*:always", "!blog:*:delete:always", "blog:*:read:published"]
      iex> matching = AshGrant.Evaluator.find_matching(permissions, "blog", "read")
      iex> length(matching)
      2

  """
  @spec find_matching(permissions(), String.t(), String.t(), atom() | nil) :: [Permission.t()]
  def find_matching(permissions, resource, action, action_type \\ nil) do
    permissions
    |> normalize_permissions()
    |> Enum.filter(&Permission.matches?(&1, resource, action, action_type))
  end

  @doc """
  Gets all instance IDs that the user has permission to access.

  Returns a list of instance IDs from all matching instance permissions
  (where instance_id != "*") for the given resource and action.

  This is used by FilterCheck to build a `WHERE id IN (...)` filter
  for instance-based access control.

  ## Examples

      iex> permissions = ["shareddoc:doc_abc:read:", "shareddoc:doc_xyz:read:"]
      iex> AshGrant.Evaluator.get_matching_instance_ids(permissions, "shareddoc", "read")
      ["doc_abc", "doc_xyz"]

      iex> permissions = ["shareddoc:*:read:always", "otherdoc:doc_abc:read:"]
      iex> AshGrant.Evaluator.get_matching_instance_ids(permissions, "shareddoc", "read")
      []

      iex> permissions = ["shareddoc:doc_abc:read:", "!shareddoc:doc_abc:read:"]
      iex> AshGrant.Evaluator.get_matching_instance_ids(permissions, "shareddoc", "read")
      []

  """
  @spec get_matching_instance_ids(permissions(), String.t(), String.t(), atom() | nil) ::
          [String.t()]
  def get_matching_instance_ids(permissions, resource, action, action_type \\ nil) do
    permissions = normalize_permissions(permissions)

    # Find all instance permissions that match resource and action
    instance_perms =
      permissions
      |> Enum.filter(fn perm ->
        Permission.instance_permission?(perm) and
          Permission.matches_resource?(perm.resource, resource) and
          Permission.matches_action?(perm.action, action, action_type)
      end)

    # Get denied instance IDs
    denied_ids =
      instance_perms
      |> Enum.filter(&Permission.deny?/1)
      |> Enum.map(& &1.instance_id)
      |> MapSet.new()

    # Get allowed instance IDs (excluding denied ones)
    instance_perms
    |> Enum.reject(&Permission.deny?/1)
    |> Enum.map(& &1.instance_id)
    |> Enum.reject(&MapSet.member?(denied_ids, &1))
    |> Enum.uniq()
  end

  @doc """
  Combines multiple permission lists with deny-wins semantics.

  This is useful when permissions come from multiple sources
  (e.g., roles + instance permissions).

  ## Examples

      iex> role_perms = ["blog:*:read:always"]
      iex> instance_perms = ["blog:blog_abc123xyz789ab:write:"]
      iex> combined = AshGrant.Evaluator.combine([role_perms, instance_perms])
      iex> AshGrant.Evaluator.has_access?(combined, "blog", "read")
      true

  """
  @spec combine([permissions()]) :: [Permission.t()]
  def combine(permission_lists) do
    permission_lists
    |> List.flatten()
    |> normalize_permissions()
  end

  @doc """
  Normalizes a list of permission representations into `%AshGrant.Permission{}` structs.

  Accepts strings, `%AshGrant.Permission{}` structs, `%AshGrant.PermissionInput{}`,
  and `Permissionable` maps — the same inputs the evaluator and checks accept.
  """
  @spec normalize_permissions(permissions()) :: [Permission.t()]
  def normalize_permissions(permissions) do
    Enum.map(permissions, &normalize_permission/1)
  end

  # Private functions

  defp normalize_permission(%Permission{} = perm), do: perm

  defp normalize_permission(%AshGrant.PermissionInput{} = input) do
    Permission.from_input(input)
  end

  defp normalize_permission(str) when is_binary(str) do
    Permission.parse!(str)
  end

  defp normalize_permission(map) when is_map(map) do
    # Check if the map implements Permissionable protocol
    if AshGrant.Permissionable.impl_for(map) do
      map
      |> AshGrant.Permissionable.to_permission_input()
      |> normalize_permission()
    else
      # Legacy: treat as a plain map with Permission fields
      struct(Permission, Map.put_new(map, :instance_id, "*"))
    end
  end

  defp normalize_permission(value) do
    # Try the Permissionable protocol for any other type
    value
    |> AshGrant.Permissionable.to_permission_input()
    |> normalize_permission()
  end
end

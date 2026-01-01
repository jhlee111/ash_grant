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

  - **Strings**: `"blog:read:all"`, `"!blog:delete:all"`
  - **Permission structs**: `%AshGrant.Permission{...}`
  - **Maps**: `%{resource: "blog", action: "read", scope: "all", deny: false}`

  All formats are automatically normalized internally.

  ## Examples

  ### Basic Access Check

      permissions = ["blog:*:read:all", "blog:*:write:own"]

      Evaluator.has_access?(permissions, "blog", "read")   # true
      Evaluator.has_access?(permissions, "blog", "write")  # true
      Evaluator.has_access?(permissions, "blog", "delete") # false

  ### Deny-Wins in Action

      permissions = [
        "blog:*:*:all",           # Allow all blog actions
        "!blog:*:delete:all"      # Deny delete
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
  | `get_instance_scope/3` | Get scope from instance permission (for ABAC conditions) |
  | `get_all_instance_scopes/3` | Get all scopes from instance permissions |
  | `find_matching/3` | Get all matching permissions (debug/introspection) |
  | `combine/1` | Merge multiple permission lists |
  """

  alias AshGrant.Permission

  @type permissions :: [Permission.t() | String.t() | map()]

  @doc """
  Checks if the given permissions grant access to a resource and action.

  Implements deny-wins: if any deny rule matches, access is denied.

  ## Examples

      iex> permissions = ["blog:*:read:all", "blog:*:write:own"]
      iex> AshGrant.Evaluator.has_access?(permissions, "blog", "read")
      true

      iex> permissions = ["blog:*:*:all", "!blog:*:delete:all"]
      iex> AshGrant.Evaluator.has_access?(permissions, "blog", "delete")
      false

  """
  @spec has_access?(permissions(), String.t(), String.t()) :: boolean()
  def has_access?(permissions, resource, action) do
    permissions = normalize_permissions(permissions)

    # Check for deny rules first (deny wins)
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action)
      end)

    if has_deny do
      false
    else
      # Check for allow rules
      Enum.any?(permissions, fn perm ->
        not Permission.deny?(perm) and Permission.matches?(perm, resource, action)
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

      iex> permissions = ["doc:doc_123:*:all", "!doc:doc_123:delete:all"]
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

      iex> permissions = ["doc:doc_123:*:all", "!doc:doc_123:delete:all"]
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

      iex> permissions = ["blog:*:read:all", "blog:*:update:own"]
      iex> AshGrant.Evaluator.get_scope(permissions, "blog", "read")
      "all"
      iex> AshGrant.Evaluator.get_scope(permissions, "blog", "update")
      "own"
      iex> AshGrant.Evaluator.get_scope(permissions, "blog", "delete")
      nil

  """
  @spec get_scope(permissions(), String.t(), String.t()) :: String.t() | nil
  def get_scope(permissions, resource, action) do
    permissions = normalize_permissions(permissions)

    # First check if denied
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action)
      end)

    if has_deny do
      nil
    else
      # Find first matching allow permission and return its scope
      permissions
      |> Enum.find(fn perm ->
        not Permission.deny?(perm) and Permission.matches?(perm, resource, action)
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

      iex> permissions = ["blog:*:read:own", "blog:*:read:published", "blog:*:read:all"]
      iex> AshGrant.Evaluator.get_all_scopes(permissions, "blog", "read")
      ["own", "published", "all"]

  """
  @spec get_all_scopes(permissions(), String.t(), String.t()) :: [String.t()]
  def get_all_scopes(permissions, resource, action) do
    permissions = normalize_permissions(permissions)

    # Check for deny first
    has_deny =
      Enum.any?(permissions, fn perm ->
        Permission.deny?(perm) and Permission.matches?(perm, resource, action)
      end)

    if has_deny do
      []
    else
      permissions
      |> Enum.filter(fn perm ->
        not Permission.deny?(perm) and Permission.matches?(perm, resource, action)
      end)
      |> Enum.map(& &1.scope)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end
  end

  @doc """
  Finds all matching permissions (both allow and deny).

  ## Examples

      iex> permissions = ["blog:*:*:all", "!blog:*:delete:all", "blog:*:read:published"]
      iex> matching = AshGrant.Evaluator.find_matching(permissions, "blog", "read")
      iex> length(matching)
      2

  """
  @spec find_matching(permissions(), String.t(), String.t()) :: [Permission.t()]
  def find_matching(permissions, resource, action) do
    permissions
    |> normalize_permissions()
    |> Enum.filter(&Permission.matches?(&1, resource, action))
  end

  @doc """
  Combines multiple permission lists with deny-wins semantics.

  This is useful when permissions come from multiple sources
  (e.g., roles + instance permissions).

  ## Examples

      iex> role_perms = ["blog:*:read:all"]
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

  # Private functions

  defp normalize_permissions(permissions) do
    Enum.map(permissions, fn
      %Permission{} = perm -> perm
      str when is_binary(str) -> Permission.parse!(str)
      map when is_map(map) -> struct(Permission, map)
    end)
  end
end

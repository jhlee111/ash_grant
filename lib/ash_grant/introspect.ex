defmodule AshGrant.Introspect do
  @moduledoc """
  Permission introspection helpers for various use cases.

  This module provides functions to query and inspect permissions
  at runtime, useful for:

  - **Admin UI**: Display what permissions a user has
  - **Permission Management**: List all available permissions for a resource
  - **Debugging**: Check why access is allowed or denied
  - **API Responses**: Return allowed actions to clients

  ## Functions Overview

  | Function | Use Case | Returns |
  |----------|----------|---------|
  | `actor_permissions/3` | Admin UI | All permissions with status |
  | `available_permissions/1` | Permission management | All possible permissions |
  | `can?/4` | Debugging | `:allow` or `:deny` with details |
  | `allowed_actions/3` | API response | List of allowed actions |
  | `permissions_for/3` | Raw access | Permission strings from resolver |

  ## Examples

      # Admin UI: What can this user do?
      Introspect.actor_permissions(Post, current_user)
      # => [%{action: "read", allowed: true, scope: "all"}, ...]

      # Permission management: What permissions exist?
      Introspect.available_permissions(Post)
      # => [%{permission_string: "post:*:read:all", action: "read", scope: "all"}, ...]

      # Debugging: Can user do this?
      Introspect.can?(Post, :update, user)
      # => {:allow, %{scope: "own"}}

      # API: What actions are available?
      Introspect.allowed_actions(Post, user)
      # => [:read, :create, :update]
  """

  alias AshGrant.{Evaluator, Info, Permission}

  @type permission_status :: %{
          action: String.t(),
          allowed: boolean(),
          denied: boolean(),
          scope: String.t() | nil,
          instance_ids: [String.t()] | nil
        }

  @type available_permission :: %{
          permission_string: String.t(),
          action: String.t(),
          scope: String.t(),
          scope_description: String.t() | nil
        }

  @doc """
  Returns all permissions for a resource with their status for a given actor.

  Useful for Admin UI to display what a user can or cannot do.

  ## Options

  - `:context` - Additional context to pass to the resolver

  ## Examples

      iex> Introspect.actor_permissions(Post, %{role: :editor})
      [
        %{action: "read", allowed: true, scope: "all", denied: false, instance_ids: nil},
        %{action: "update", allowed: true, scope: "own", denied: false, instance_ids: nil},
        %{action: "destroy", allowed: false, scope: nil, denied: false, instance_ids: nil}
      ]

  """
  @spec actor_permissions(module(), term(), keyword()) :: [permission_status()]
  def actor_permissions(resource, actor, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    resource_name = Info.resource_name(resource)
    permissions = permissions_for(resource, actor, context: context)
    actions = get_resource_actions(resource)

    Enum.map(actions, fn action ->
      action_name = to_string(action.name)

      # Check RBAC permissions
      scopes = Evaluator.get_all_scopes(permissions, resource_name, action_name)

      # Check for deny
      has_deny = has_deny_permission?(permissions, resource_name, action_name)

      # Check instance permissions
      instance_ids = Evaluator.get_matching_instance_ids(permissions, resource_name, action_name)

      # Determine status
      allowed = (scopes != [] or instance_ids != []) and not has_deny
      scope = if scopes != [], do: hd(scopes), else: nil

      %{
        action: action_name,
        allowed: allowed,
        denied: has_deny,
        scope: scope,
        instance_ids: if(instance_ids != [], do: instance_ids, else: nil)
      }
    end)
  end

  @doc """
  Returns all available permissions for a resource.

  Useful for permission management UI to show what permissions can be assigned.

  ## Examples

      iex> Introspect.available_permissions(Post)
      [
        %{permission_string: "post:*:read:all", action: "read", scope: "all", scope_description: nil},
        %{permission_string: "post:*:read:own", action: "read", scope: "own", scope_description: "..."},
        ...
      ]

  """
  @spec available_permissions(module()) :: [available_permission()]
  def available_permissions(resource) do
    resource_name = Info.resource_name(resource)
    actions = get_resource_actions(resource)
    scopes = Info.scopes(resource)

    # Generate permission for each action + scope combination
    for action <- actions,
        scope <- scopes do
      scope_name = to_string(scope.name)

      %{
        permission_string: "#{resource_name}:*:#{action.name}:#{scope_name}",
        action: to_string(action.name),
        scope: scope_name,
        scope_description: scope.description
      }
    end
  end

  @doc """
  Simple permission check returning `:allow` or `:deny` with details.

  Useful for debugging authorization issues.

  ## Options

  - `:context` - Additional context to pass to the resolver

  ## Examples

      iex> Introspect.can?(Post, :read, %{role: :editor})
      {:allow, %{scope: "all", instance_ids: nil}}

      iex> Introspect.can?(Post, :destroy, %{role: :viewer})
      {:deny, %{reason: :no_permission}}

      iex> Introspect.can?(Post, :read, nil)
      {:deny, %{reason: :no_actor}}

  """
  @spec can?(module(), atom(), term(), keyword()) ::
          {:allow, map()} | {:deny, map()}
  def can?(resource, action, actor, opts \\ []) do
    if actor == nil do
      {:deny, %{reason: :no_actor}}
    else
      context = Keyword.get(opts, :context, %{})
      resource_name = Info.resource_name(resource)
      action_name = to_string(action)
      permissions = permissions_for(resource, actor, context: context)

      # Check for deny first
      has_deny = has_deny_permission?(permissions, resource_name, action_name)

      if has_deny do
        {:deny, %{reason: :denied_by_rule}}
      else
        # Check RBAC scopes
        scopes = Evaluator.get_all_scopes(permissions, resource_name, action_name)

        # Check instance permissions
        instance_ids =
          Evaluator.get_matching_instance_ids(permissions, resource_name, action_name)

        cond do
          scopes != [] ->
            {:allow, %{scope: hd(scopes), instance_ids: nil}}

          instance_ids != [] ->
            {:allow, %{scope: nil, instance_ids: instance_ids}}

          true ->
            {:deny, %{reason: :no_permission}}
        end
      end
    end
  end

  @doc """
  Returns list of allowed actions for an actor.

  Useful for API responses to tell clients what they can do.

  ## Options

  - `:context` - Additional context to pass to the resolver
  - `:detailed` - When `true`, returns detailed info instead of just action names

  ## Examples

      iex> Introspect.allowed_actions(Post, %{role: :editor})
      [:read, :create, :update]

      iex> Introspect.allowed_actions(Post, %{role: :editor}, detailed: true)
      [
        %{action: :read, scope: "all", instance_ids: nil},
        %{action: :create, scope: "all", instance_ids: nil},
        %{action: :update, scope: "own", instance_ids: nil}
      ]

  """
  @spec allowed_actions(module(), term(), keyword()) :: [atom()] | [map()]
  def allowed_actions(resource, actor, opts \\ []) do
    if actor == nil do
      []
    else
      detailed = Keyword.get(opts, :detailed, false)
      perms = actor_permissions(resource, actor, opts)

      allowed = Enum.filter(perms, & &1.allowed)

      if detailed do
        Enum.map(allowed, fn p ->
          %{
            action: String.to_atom(p.action),
            scope: p.scope,
            instance_ids: p.instance_ids
          }
        end)
      else
        Enum.map(allowed, &String.to_atom(&1.action))
      end
    end
  end

  @doc """
  Returns raw permissions from the resolver for an actor.

  Useful when you need direct access to permission strings.

  ## Options

  - `:context` - Additional context to pass to the resolver

  ## Examples

      iex> Introspect.permissions_for(Post, %{role: :editor})
      ["post:*:read:all", "post:*:update:own", "post:*:create:all"]

  """
  @spec permissions_for(module(), term(), keyword()) :: [String.t()]
  def permissions_for(resource, actor, opts \\ []) do
    if actor == nil do
      []
    else
      context = Keyword.get(opts, :context, %{})

      case Info.resolver(resource) do
        nil ->
          []

        resolver when is_function(resolver, 2) ->
          (resolver.(actor, context) || [])
          |> normalize_to_strings()

        resolver when is_atom(resolver) ->
          (resolver.resolve(actor, context) || [])
          |> normalize_to_strings()
      end
    end
  end

  # Private functions

  defp get_resource_actions(resource) do
    Ash.Resource.Info.actions(resource)
  end

  defp has_deny_permission?(permissions, resource_name, action_name) do
    permissions
    |> Enum.map(&normalize_permission/1)
    |> Enum.any?(fn perm ->
      Permission.deny?(perm) and Permission.matches?(perm, resource_name, action_name)
    end)
  end

  defp normalize_permission(str) when is_binary(str) do
    Permission.parse!(str)
  end

  defp normalize_permission(%Permission{} = perm), do: perm

  defp normalize_permission(%AshGrant.PermissionInput{} = input) do
    Permission.from_input(input)
  end

  defp normalize_permission(map) when is_map(map) do
    if AshGrant.Permissionable.impl_for(map) do
      map
      |> AshGrant.Permissionable.to_permission_input()
      |> normalize_permission()
    else
      struct(Permission, Map.put_new(map, :instance_id, "*"))
    end
  end

  defp normalize_to_strings(permissions) do
    Enum.map(permissions, fn
      str when is_binary(str) -> str
      %Permission{} = perm -> Permission.to_string(perm)
      %AshGrant.PermissionInput{string: str} -> str
      other -> inspect(other)
    end)
  end
end

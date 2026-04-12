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
      # => [%{action: "read", allowed: true, scope: "always", field_groups: []}, ...]

      # Permission management: What permissions exist?
      Introspect.available_permissions(Post)
      # => [%{permission_string: "post:*:read:always", action: "read", scope: "always", field_group: nil}, ...]

      # Debugging: Can user do this?
      Introspect.can?(Post, :update, user)
      # => {:allow, %{scope: "own", instance_ids: nil, field_groups: []}}

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
          instance_ids: [String.t()] | nil,
          field_groups: [String.t()]
        }

  @type available_permission :: %{
          permission_string: String.t(),
          action: String.t(),
          scope: String.t(),
          scope_description: String.t() | nil,
          field_group: String.t() | nil
        }

  @doc """
  Returns all permissions for a resource with their status for a given actor.

  Useful for Admin UI to display what a user can or cannot do.

  ## Options

  - `:context` - Additional context to pass to the resolver

  ## Examples

      iex> Introspect.actor_permissions(Post, %{role: :editor})
      [
        %{action: "read", allowed: true, scope: "always", denied: false, instance_ids: nil, field_groups: []},
        %{action: "update", allowed: true, scope: "own", denied: false, instance_ids: nil, field_groups: []},
        %{action: "destroy", allowed: false, scope: nil, denied: false, instance_ids: nil, field_groups: []}
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
      action_type = action.type

      # Check RBAC permissions
      scopes = Evaluator.get_all_scopes(permissions, resource_name, action_name, action_type)

      # Check for deny
      has_deny = has_deny_permission?(permissions, resource_name, action_name, action_type)

      # Check instance permissions
      instance_ids =
        Evaluator.get_matching_instance_ids(permissions, resource_name, action_name, action_type)

      # Check field groups
      field_groups =
        Evaluator.get_all_field_groups(permissions, resource_name, action_name, action_type)

      # Determine status
      allowed = (scopes != [] or instance_ids != []) and not has_deny
      scope = if scopes != [], do: hd(scopes), else: nil

      %{
        action: action_name,
        allowed: allowed,
        denied: has_deny,
        scope: scope,
        instance_ids: if(instance_ids != [], do: instance_ids, else: nil),
        field_groups: field_groups
      }
    end)
  end

  @doc """
  Returns all available permissions for a resource.

  Useful for permission management UI to show what permissions can be assigned.

  ## Examples

      iex> Introspect.available_permissions(Post)
      [
        %{permission_string: "post:*:read:always", action: "read", scope: "always", scope_description: nil, field_group: nil},
        %{permission_string: "post:*:read:own", action: "read", scope: "own", scope_description: "...", field_group: nil},
        ...
      ]

  """
  @spec available_permissions(module()) :: [available_permission()]
  def available_permissions(resource) do
    resource_name = Info.resource_name(resource)
    actions = get_resource_actions(resource)
    scopes = Info.scopes(resource)
    field_groups = Info.field_groups(resource)

    # Generate base permission for each action + scope combination (4-part)
    base_permissions =
      for action <- actions,
          scope <- scopes do
        scope_name = to_string(scope.name)

        %{
          permission_string: "#{resource_name}:*:#{action.name}:#{scope_name}",
          action: to_string(action.name),
          scope: scope_name,
          scope_description: scope.description,
          field_group: nil
        }
      end

    # Generate field_group permissions for each action + scope + field_group (5-part)
    field_group_permissions =
      if field_groups != [] do
        for action <- actions,
            scope <- scopes,
            fg <- field_groups do
          scope_name = to_string(scope.name)
          fg_name = to_string(fg.name)

          %{
            permission_string: "#{resource_name}:*:#{action.name}:#{scope_name}:#{fg_name}",
            action: to_string(action.name),
            scope: scope_name,
            scope_description: scope.description,
            field_group: fg_name
          }
        end
      else
        []
      end

    base_permissions ++ field_group_permissions
  end

  @doc """
  Simple permission check returning `:allow` or `:deny` with details.

  Useful for debugging authorization issues.

  ## Options

  - `:context` - Additional context to pass to the resolver

  ## Examples

      iex> Introspect.can?(Post, :read, %{role: :editor})
      {:allow, %{scope: "always", instance_ids: nil, field_groups: []}}

      iex> Introspect.can?(Post, :destroy, %{role: :viewer})
      {:deny, %{reason: :no_permission}}

      iex> Introspect.can?(Post, :read, nil)
      {:deny, %{reason: :no_actor}}

  """
  @spec can?(module(), atom(), term(), keyword()) ::
          {:allow, map()} | {:deny, map()}
  def can?(resource, action, actor, opts \\ [])

  def can?(_resource, _action, nil, _opts) do
    {:deny, %{reason: :no_actor}}
  end

  def can?(resource, action, actor, opts) do
    context = Keyword.get(opts, :context, %{})
    resource_name = Info.resource_name(resource)
    action_name = to_string(action)
    permissions = permissions_for(resource, actor, context: context)
    action_type = resolve_action_type(resource, action)

    if has_deny_permission?(permissions, resource_name, action_name, action_type) do
      {:deny, %{reason: :denied_by_rule}}
    else
      evaluate_allow(resource, permissions, resource_name, action_name, action_type)
    end
  end

  defp resolve_action_type(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: type} -> type
      _ -> nil
    end
  end

  defp evaluate_allow(resource, permissions, resource_name, action_name, action_type) do
    scopes = Evaluator.get_all_scopes(permissions, resource_name, action_name, action_type)

    instance_ids =
      Evaluator.get_matching_instance_ids(permissions, resource_name, action_name, action_type)

    field_groups =
      Evaluator.get_all_field_groups(permissions, resource_name, action_name, action_type)

    # Check parent instance permissions via scope_through
    has_parent_instance =
      has_parent_instance_access?(resource, permissions, action_name, action_type)

    cond do
      scopes != [] ->
        {:allow, %{scope: hd(scopes), instance_ids: nil, field_groups: field_groups}}

      instance_ids != [] ->
        {:allow, %{scope: nil, instance_ids: instance_ids, field_groups: field_groups}}

      has_parent_instance ->
        {:allow,
         %{scope: nil, instance_ids: nil, field_groups: field_groups, via: :scope_through}}

      true ->
        {:deny, %{reason: :no_permission}}
    end
  end

  defp has_parent_instance_access?(resource, permissions, action_name, action_type) do
    Info.scope_throughs(resource)
    |> Enum.any?(fn scope_through ->
      parent_resource =
        case scope_through.resource do
          nil ->
            case Ash.Resource.Info.relationship(resource, scope_through.relationship) do
              nil -> nil
              rel -> rel.destination
            end

          explicit ->
            explicit
        end

      if parent_resource do
        parent_resource_name = Info.resource_name(parent_resource)

        parent_ids =
          Evaluator.get_matching_instance_ids(
            permissions,
            parent_resource_name,
            action_name,
            action_type
          )

        parent_ids != []
      else
        false
      end
    end)
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
        %{action: :read, scope: "always", instance_ids: nil, field_groups: []},
        %{action: :create, scope: "always", instance_ids: nil, field_groups: []},
        %{action: :update, scope: "own", instance_ids: nil, field_groups: []}
      ]

  """
  @spec allowed_actions(module(), term(), keyword()) :: [atom()] | [map()]
  def allowed_actions(resource, actor, opts \\ [])

  def allowed_actions(_resource, nil, _opts), do: []

  def allowed_actions(resource, actor, opts) do
    detailed = Keyword.get(opts, :detailed, false)
    perms = actor_permissions(resource, actor, opts)
    allowed = Enum.filter(perms, & &1.allowed)

    format_allowed_actions(allowed, detailed)
  end

  defp format_allowed_actions(allowed, true) do
    Enum.map(allowed, fn p ->
      %{
        action: String.to_atom(p.action),
        scope: p.scope,
        instance_ids: p.instance_ids,
        field_groups: p.field_groups
      }
    end)
  end

  defp format_allowed_actions(allowed, false) do
    Enum.map(allowed, &String.to_atom(&1.action))
  end

  @doc """
  Returns raw permissions from the resolver for an actor.

  Useful when you need direct access to permission strings.

  ## Options

  - `:context` - Additional context to pass to the resolver

  ## Examples

      iex> Introspect.permissions_for(Post, %{role: :editor})
      ["post:*:read:always", "post:*:update:own", "post:*:create:always"]

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

  defp has_deny_permission?(permissions, resource_name, action_name, action_type) do
    permissions
    |> Enum.map(&normalize_permission/1)
    |> Enum.any?(fn perm ->
      Permission.deny?(perm) and
        Permission.matches?(perm, resource_name, action_name, action_type)
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

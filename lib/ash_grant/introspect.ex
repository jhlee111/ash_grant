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
      # => {:allow, %{scope: "own", scopes: ["own"], instance_ids: nil, field_groups: []}}

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

  @type resource_summary :: %{
          resource: module(),
          resource_key: String.t(),
          allowed_actions: [atom()],
          permissions: [permission_status()]
        }

  @type available_permission :: %{
          permission_string: String.t(),
          action: String.t(),
          scope: String.t(),
          scope_description: String.t() | nil,
          field_group: String.t() | nil
        }

  @doc """
  Lists Ash domains configured under `:ash_domains` across all started
  applications.

  AshGrant reuses the standard Ash convention (`config :my_app, ash_domains: [...]`)
  rather than introducing its own configuration key. Any domain registered this
  way is a candidate for resource discovery.

  ## Examples

      iex> AshGrant.Introspect.list_domains()
      [MyApp.Blog, MyApp.Accounts]

  """
  @spec list_domains() :: [module()]
  def list_domains do
    for {app, _, _} <- Application.started_applications(),
        domain <- Application.get_env(app, :ash_domains, []),
        uniq: true,
        do: domain
  end

  @doc """
  Lists every resource that uses the `AshGrant` extension.

  By default, domains are auto-discovered via `list_domains/0`. Pass
  `:domains` to scope the lookup to a specific set (useful in tests and
  multi-tenant setups).

  ## Options

  - `:domains` - Explicit list of Ash domain modules to inspect. When
    omitted, uses `list_domains/0`.

  ## Examples

      iex> AshGrant.Introspect.list_resources()
      [MyApp.Blog.Post, MyApp.Blog.Comment, ...]

      iex> AshGrant.Introspect.list_resources(domains: [MyApp.Blog])
      [MyApp.Blog.Post, MyApp.Blog.Comment]

  """
  @spec list_resources(keyword()) :: [module()]
  def list_resources(opts \\ []) do
    domains = Keyword.get_lazy(opts, :domains, &list_domains/0)

    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        uses_ash_grant?(resource),
        uniq: true,
        do: resource
  end

  @doc """
  Resolves a resource key string to its module, if any registered resource
  declares that name.

  Matching is case-sensitive and uses `AshGrant.Info.resource_name/1`
  (either the explicit `resource_name "..."` DSL value or the auto-derived
  default). This enables external tools to accept resource names as strings
  without knowing Elixir module references.

  ## Examples

      iex> AshGrant.Introspect.find_resource_by_key("blog")
      {:ok, MyApp.Blog.Post}

      iex> AshGrant.Introspect.find_resource_by_key("unknown")
      :error

  """
  @spec find_resource_by_key(String.t()) :: {:ok, module()} | :error
  def find_resource_by_key(""), do: :error

  def find_resource_by_key(key) when is_binary(key) do
    list_resources()
    |> Enum.find(fn resource -> Info.resource_name(resource) == key end)
    |> case do
      nil -> :error
      resource -> {:ok, resource}
    end
  end

  @doc """
  Explains an access decision using string/ID inputs.

  Resolves `resource_key` to a resource module via `find_resource_by_key/1`,
  then loads the actor by calling `load_actor/1` on the resource's
  permission resolver module, and finally delegates to
  `AshGrant.explain/4`.

  This is the primary entry point for external tools (admin dashboards,
  LLM agents, `mix ash_grant.explain`) that only know string identifiers.

  ## Options (keyword list)

  - `:actor_id` - Required. Identifier to pass to `resolver.load_actor/1`.
  - `:resource_key` - Required. Resource name (matches `AshGrant.Info.resource_name/1`).
  - `:action` - Required. Action name as an atom.
  - `:context` - Optional. Additional context map passed to the resolver.

  ## Returns

  - `{:ok, AshGrant.Explanation.t()}`
  - `{:error, :unknown_resource}` - no resource matched `resource_key`
  - `{:error, :actor_loader_not_implemented}` - resolver cannot load actors
    by ID (either it's an anonymous function or the module doesn't export
    the optional `load_actor/1` callback)
  - `{:error, :actor_not_found}` - resolver's `load_actor/1` returned `:error`

  ## Examples

      iex> AshGrant.Introspect.explain_by_identifier(
      ...>   actor_id: "user_1",
      ...>   resource_key: "post",
      ...>   action: :read
      ...> )
      {:ok, %AshGrant.Explanation{decision: :allow, ...}}

  """
  @spec explain_by_identifier(keyword()) ::
          {:ok, AshGrant.Explanation.t()}
          | {:error, :unknown_resource | :actor_loader_not_implemented | :actor_not_found}
  def explain_by_identifier(opts) when is_list(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    resource_key = Keyword.fetch!(opts, :resource_key)
    action = Keyword.fetch!(opts, :action)
    context = Keyword.get(opts, :context, %{})

    with {:ok, resource} <- resolve_resource(resource_key),
         {:ok, actor} <- load_actor_for(resource, actor_id) do
      {:ok, AshGrant.explain(resource, action, actor, context)}
    end
  end

  @doc """
  Identifier-based variant of `can?/4`.

  Same resolution flow as `explain_by_identifier/1` (resource key →
  module, actor id → actor), then delegates to `can?/4`.

  ## Options

  - `:context` - Optional. Additional context map passed to the resolver.

  ## Returns

  - `{:allow, map()}` / `{:deny, map()}` - same shape as `can?/4`
  - `{:error, :unknown_resource | :actor_loader_not_implemented | :actor_not_found}`

  ## Examples

      iex> AshGrant.Introspect.can_by_identifier("user_1", "post", :read)
      {:allow, %{scope: "always", scopes: ["always"], instance_ids: nil, field_groups: []}}

  """
  @spec can_by_identifier(term(), String.t(), atom(), keyword()) ::
          {:allow, map()}
          | {:deny, map()}
          | {:error, :unknown_resource | :actor_loader_not_implemented | :actor_not_found}
  def can_by_identifier(actor_id, resource_key, action, opts \\ []) do
    with {:ok, resource} <- resolve_resource(resource_key),
         {:ok, actor} <- load_actor_for(resource, actor_id) do
      can?(resource, action, actor, opts)
    end
  end

  @doc """
  Identifier-based variant of `actor_permissions/3`.

  ## Options

  - `:context` - Optional. Additional context map passed to the resolver.

  ## Returns

  - `{:ok, [permission_status()]}`
  - `{:error, :unknown_resource | :actor_loader_not_implemented | :actor_not_found}`

  ## Examples

      iex> AshGrant.Introspect.actor_permissions_by_id("user_1", "post")
      {:ok, [%{action: "read", allowed: true, ...}, ...]}

  """
  @spec actor_permissions_by_id(term(), String.t(), keyword()) ::
          {:ok, [permission_status()]}
          | {:error, :unknown_resource | :actor_loader_not_implemented | :actor_not_found}
  def actor_permissions_by_id(actor_id, resource_key, opts \\ []) do
    with {:ok, resource} <- resolve_resource(resource_key),
         {:ok, actor} <- load_actor_for(resource, actor_id) do
      {:ok, actor_permissions(resource, actor, opts)}
    end
  end

  defp resolve_resource(resource_key) do
    case find_resource_by_key(resource_key) do
      {:ok, resource} -> {:ok, resource}
      :error -> {:error, :unknown_resource}
    end
  end

  defp load_actor_for(resource, actor_id) do
    case Info.resolver(resource) do
      resolver when is_atom(resolver) and not is_nil(resolver) ->
        load_actor_via(resolver, actor_id)

      _ ->
        {:error, :actor_loader_not_implemented}
    end
  end

  defp load_actor_via(resolver, actor_id) do
    Code.ensure_loaded(resolver)

    if function_exported?(resolver, :load_actor, 1) do
      case resolver.load_actor(actor_id) do
        {:ok, actor} -> {:ok, actor}
        :error -> {:error, :actor_not_found}
      end
    else
      {:error, :actor_loader_not_implemented}
    end
  end

  @doc """
  Summarizes everything an actor can do across a set of resources.

  Iterates the resource list, calls `actor_permissions/3` per resource,
  and aggregates the results into a per-resource summary. This is the
  "single question" admin dashboards and LLM tools ask to build a
  user's global access overview in one call.

  ## Options

  - `:resources` - Explicit list of resource modules to summarize. When
    omitted, uses `list_resources/1` (optionally scoped by `:domains`).
  - `:domains` - Restrict auto-discovery to these Ash domains.
    Ignored when `:resources` is given.
  - `:context` - Context map passed through to each resource's resolver.
  - `:only_with_access` - When `true`, drops resources where
    `allowed_actions` is empty. Defaults to `false`.

  ## Returns

  A list of maps with:
  - `:resource` - the resource module
  - `:resource_key` - the resource name used in permission strings
  - `:allowed_actions` - list of action atoms the actor is currently
    allowed to perform
  - `:permissions` - the full `actor_permissions/3` output for the
    resource (one entry per action, with allowed/denied/scope details)

  Returns `[]` when `actor` is `nil`.

  ## Examples

      iex> AshGrant.Introspect.summarize_actor(%{id: "u1", permissions: ["post:*:read:always"]})
      [
        %{
          resource: MyApp.Blog.Post,
          resource_key: "post",
          allowed_actions: [:read],
          permissions: [...]
        },
        ...
      ]

  """
  @spec summarize_actor(term(), keyword()) :: [resource_summary()]
  def summarize_actor(actor, opts \\ [])

  def summarize_actor(nil, _opts), do: []

  def summarize_actor(actor, opts) do
    resources =
      case Keyword.fetch(opts, :resources) do
        {:ok, explicit} -> explicit
        :error -> list_resources(Keyword.take(opts, [:domains]))
      end

    only_with_access = Keyword.get(opts, :only_with_access, false)
    per_resource_opts = Keyword.take(opts, [:context])

    resources
    |> Enum.map(&build_resource_summary(&1, actor, per_resource_opts))
    |> maybe_filter_with_access(only_with_access)
  end

  defp build_resource_summary(resource, actor, opts) do
    permissions = actor_permissions(resource, actor, opts)

    allowed_actions =
      permissions
      |> Enum.filter(& &1.allowed)
      |> Enum.map(&String.to_atom(&1.action))

    %{
      resource: resource,
      resource_key: Info.resource_name(resource),
      allowed_actions: allowed_actions,
      permissions: permissions
    }
  end

  defp maybe_filter_with_access(summaries, true) do
    Enum.reject(summaries, &(&1.allowed_actions == []))
  end

  defp maybe_filter_with_access(summaries, _false), do: summaries

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
      {:allow, %{scope: "always", scopes: ["always"], instance_ids: nil, field_groups: []}}

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
        # :scopes carries ALL matching grants' scopes (union, #123);
        # :scope stays as the first one for backward compatibility.
        {:allow,
         %{scope: hd(scopes), scopes: scopes, instance_ids: nil, field_groups: field_groups}}

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
      parent_resource = scope_through_parent_resource(resource, scope_through)

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

  defp scope_through_parent_resource(resource, scope_through) do
    case scope_through.resource do
      nil ->
        case Ash.Resource.Info.relationship(resource, scope_through.relationship) do
          nil -> nil
          rel -> rel.destination
        end

      explicit ->
        explicit
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

  defp uses_ash_grant?(resource) do
    AshGrant in Spark.extensions(resource)
  rescue
    _ -> false
  end

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

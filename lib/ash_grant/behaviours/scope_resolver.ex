defmodule AshGrant.ScopeResolver do
  @moduledoc """
  Behaviour for resolving scopes to filter expressions.

  Implement this behaviour to define what each scope means
  in terms of data filtering.

  ## Built-in Scopes

  Some scopes have conventional meanings:

  - `"all"` - No filtering, access to all records
  - `"own"` - Records owned by the actor (requires `owner_field` config)

  ## Examples

  ### Simple Blog Scopes

      defmodule MyApp.BlogScopeResolver do
        @behaviour AshGrant.ScopeResolver
        require Ash.Expr

        @impl true
        def resolve("all", _context), do: true

        @impl true
        def resolve("own", %{actor: actor}) do
          Ash.Expr.expr(author_id == ^actor.id)
        end

        @impl true
        def resolve("published", _context) do
          Ash.Expr.expr(status == :published)
        end

        @impl true
        def resolve("own_draft", %{actor: actor}) do
          Ash.Expr.expr(author_id == ^actor.id and status == :draft)
        end

        @impl true
        def resolve(scope, _context) do
          raise "Unknown scope: \#{scope}"
        end
      end

  ### Organization Hierarchy Scopes

      defmodule MyApp.OrgScopeResolver do
        @behaviour AshGrant.ScopeResolver
        require Ash.Expr

        @impl true
        def resolve("all", _context), do: true

        @impl true
        def resolve("org_self", %{actor: actor}) do
          Ash.Expr.expr(organization_unit_id == ^actor.org_unit_id)
        end

        @impl true
        def resolve("org_subtree", %{actor: actor, tenant: tenant}) do
          ids = MyApp.OrgUnit.descendant_ids(actor.org_unit_id, tenant)
          Ash.Expr.expr(organization_unit_id in ^ids)
        end

        @impl true
        def resolve("org_global", %{tenant: tenant}) do
          Ash.Expr.expr(tenant_id == ^tenant)
        end
      end

  ### Combined Scopes

      defmodule MyApp.CombinedScopeResolver do
        @behaviour AshGrant.ScopeResolver
        require Ash.Expr

        @impl true
        def resolve("own_" <> rest, context) do
          # Combine "own" with another condition
          own_expr = resolve_own(context)
          other_expr = resolve(rest, context)

          Ash.Expr.expr(^own_expr and ^other_expr)
        end

        defp resolve_own(%{actor: actor, owner_field: field}) do
          Ash.Expr.expr(^ref(field) == ^actor.id)
        end
      end

  """

  @type scope :: String.t()
  @type context :: map()
  @type filter :: Ash.Expr.t() | boolean()

  @doc """
  Resolves a scope to a filter expression.

  ## Parameters

  - `scope` - The scope string from the permission (e.g., "all", "own", "published")
  - `context` - Context map containing:
    - `:actor` - The actor requesting access
    - `:resource` - The resource module
    - `:action` - The action being performed
    - `:tenant` - The current tenant
    - `:owner_field` - The field that identifies ownership (from DSL config)

  ## Returns

  - `true` - No filtering (allow all)
  - `false` - Block all
  - `Ash.Expr.t()` - A filter expression to apply

  """
  @callback resolve(scope(), context()) :: filter()

  @doc """
  Optional callback to list all known scopes.

  This can be used for validation and documentation.
  """
  @callback known_scopes() :: [scope()]

  @optional_callbacks [known_scopes: 0]
end

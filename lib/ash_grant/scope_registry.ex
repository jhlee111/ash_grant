defmodule AshGrant.ScopeRegistry do
  @moduledoc """
  Config-level registry for scopes shared across every resource in an app.

  Resources that `use AshGrant` pick up registry scopes automatically through
  `AshGrant.Info.scopes/1`, and can override a registry scope by declaring one
  of the same name in their own `ash_grant do` block. A domain with
  `AshGrant.Domain` can do the same. Precedence is:

      resource > domain > registry

  Same-name wins at each level.

  ## Example

      # lib/my_app/global_scopes.ex
      defmodule MyApp.GlobalScopes do
        use AshGrant.ScopeRegistry

        scopes do
          scope :always, true
          scope :own, expr(author_id == ^actor(:id))
          scope :same_org, expr(org_id == ^actor(:org_id))
        end
      end

      # config/config.exs
      config :ash_grant, scope_registry: MyApp.GlobalScopes

  Every resource that uses `AshGrant` now sees `:always`, `:own`, and
  `:same_org` as if they had been declared on the resource, unless the
  resource (or its domain) declares a scope with the same name.

  ## Inheritance

  `scope :own_draft, [:own], expr(status == :draft)` is supported. Parents are
  looked up through `AshGrant.Info.get_scope/2`, so a registry scope can
  inherit from a domain or resource scope and vice versa.
  """

  defmodule Dsl do
    @moduledoc false

    @scopes %Spark.Dsl.Section{
      name: :scopes,
      describe: "Scopes shared across every resource that uses `AshGrant`.",
      imports: [Ash.Expr],
      entities: [AshGrant.Dsl.scope_entity()]
    }

    use Spark.Dsl.Extension, sections: [@scopes]
  end

  use Spark.Dsl, default_extensions: [extensions: [Dsl]]

  @doc """
  Returns the scopes defined by the configured registry module, or `[]` when
  no registry is configured or the configured module is not a
  `ScopeRegistry`.
  """
  @spec scopes() :: [AshGrant.Dsl.Scope.t()]
  def scopes do
    case Application.get_env(:ash_grant, :scope_registry) do
      nil -> []
      module when is_atom(module) -> scopes_for(module)
    end
  end

  @spec scopes_for(module()) :: [AshGrant.Dsl.Scope.t()]
  defp scopes_for(module) do
    Spark.Dsl.Extension.get_entities(module, [:scopes])
  rescue
    _ -> []
  end
end

defmodule AshGrant.Domain.Info do
  @moduledoc """
  Introspection helpers for AshGrant domain-level DSL configuration.

  Used internally by `AshGrant.Info` to read domain-level settings and merge
  them into resources at runtime. Merging happens on each call rather than at
  compile time to avoid a compile-time cycle between resource and domain
  when the domain also defines `code_interface` entries targeting the
  resource.
  """

  @doc """
  Gets the permission resolver configured on the domain.

  Returns `nil` if the domain does not use the `AshGrant.Domain` extension
  or has no `resolver` configured.
  """
  @spec resolver(domain :: Ash.Domain.t()) :: module() | function() | nil
  def resolver(domain) do
    Spark.Dsl.Extension.get_opt(domain, [:ash_grant], :resolver)
  end

  @doc """
  Gets all scope definitions from the domain.

  Returns `[]` if the domain does not use the `AshGrant.Domain` extension.
  """
  @spec scopes(domain :: Ash.Domain.t()) :: [AshGrant.Dsl.Scope.t()]
  def scopes(domain) do
    Spark.Dsl.Extension.get_entities(domain, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.Scope{}, &1))
  end

  @doc """
  Gets a specific scope by name from the domain.
  """
  @spec get_scope(domain :: Ash.Domain.t(), name :: atom()) :: AshGrant.Dsl.Scope.t() | nil
  def get_scope(domain, name) do
    scopes(domain)
    |> Enum.find(&(&1.name == name))
  end

  @doc """
  Returns true if the domain has the `AshGrant.Domain` extension configured.
  """
  @spec configured?(domain :: Ash.Domain.t()) :: boolean()
  def configured?(domain) do
    extensions = Spark.extensions(domain)
    AshGrant.Domain in extensions
  rescue
    _ -> false
  end
end

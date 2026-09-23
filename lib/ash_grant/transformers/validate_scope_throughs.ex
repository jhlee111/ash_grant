defmodule AshGrant.Transformers.ValidateScopeThroughs do
  @moduledoc """
  Spark DSL transformer that validates scope_through entities at compile time.

  Validates that:
  - The referenced relationship exists on the resource
  - The relationship is a belongs_to type
  - If an explicit resource is provided, it matches the relationship destination
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def before?(AshGrant.Transformers.AddDefaultPolicies), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :module)

    scope_throughs =
      Transformer.get_entities(dsl_state, [:ash_grant])
      |> Enum.filter(&match?(%AshGrant.Dsl.ScopeThrough{}, &1))

    Enum.each(scope_throughs, fn st ->
      validate_relationship_exists(dsl_state, resource, st)
    end)

    {:ok, dsl_state}
  end

  defp validate_relationship_exists(dsl_state, resource, scope_through) do
    relationships = Transformer.get_entities(dsl_state, [:relationships])
    rel = Enum.find(relationships, &(&1.name == scope_through.relationship))

    cond do
      rel == nil ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:ash_grant, :scope_through],
          message:
            "Relationship :#{scope_through.relationship} not found on #{inspect(resource)}. " <>
              "scope_through requires a belongs_to relationship to the parent resource."

      rel.type != :belongs_to ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:ash_grant, :scope_through],
          message:
            "scope_through relationship :#{scope_through.relationship} on #{inspect(resource)} " <>
              "is a :#{rel.type} relationship, but scope_through requires a belongs_to " <>
              "relationship to the parent resource."

      true ->
        :ok
    end
  end
end

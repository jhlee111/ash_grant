defmodule AshGrant.Transformers.AddCanPerformCalculations do
  @moduledoc """
  Spark DSL transformer that generates CanPerform calculations from DSL entities.

  This transformer reads `can_perform` entities and the `can_perform_actions`
  option from the `ash_grant` section and adds corresponding boolean calculations
  using `Ash.Resource.Builder.add_new_calculation/5`.

  ## Usage Rules

  - **`can_perform_actions`** (batch) and **`can_perform`** (individual entity) can coexist.
    Both are merged into a single list before generating calculations.
  - **Naming**: `can_perform_actions [:update]` generates `:can_update?`.
    `can_perform :update` also generates `:can_update?` by default.
    Use the `name:` option on `can_perform` for a custom name (e.g., `name: :editable?`).
  - **Duplicate handling**: Uses `add_new_calculation` (not `add_calculation`), so if
    the same calculation name already exists (from an explicit `calculations` block or
    a duplicate DSL entry), it is silently skipped. The first definition wins.
  - **Coexistence with explicit module**: DSL-generated calculations and manually declared
    `{AshGrant.Calculation.CanPerform, ...}` calculations coexist safely.
  - **Resource auto-detection**: The transformer injects the resource module automatically
    via `Transformer.get_persisted(dsl_state, :module)`, so users do not need to pass
    `resource: __MODULE__` when using the DSL.
  - **Public by default**: All DSL-generated calculations are `public?: true` by default.
    The `can_perform` entity supports `public?: false` for private calculations.
  - **Action validation**: At compile time, the transformer verifies that each referenced
    action name exists on the resource. A typo like `can_perform_actions [:foobar]` raises
    a `Spark.Error.DslError` with the list of available actions.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # AddFieldPolicies must see the generated calculations, or its catch-all
  # field policy and cache skip them and they read back as %Ash.ForbiddenField{}.
  # Both transformers otherwise claim after?(_), which Spark treats as no edge.
  @impl true
  def after?(AshGrant.Transformers.AddFieldPolicies), do: false
  def after?(_), do: true

  @impl true
  def before?(Ash.Policy.Authorizer), do: true
  def before?(AshGrant.Transformers.AddFieldPolicies), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :module)

    # Collect from can_perform entities
    entities =
      dsl_state
      |> Transformer.get_entities([:ash_grant])
      |> Enum.filter(&match?(%AshGrant.Dsl.CanPerform{}, &1))

    # Collect from can_perform_actions option
    batch_actions =
      Transformer.get_option(dsl_state, [:ash_grant], :can_perform_actions) || []

    # Build combined list: [{calc_name, action_string, public?}, ...]
    calcs_from_entities =
      Enum.map(entities, fn entity ->
        name = entity.name || :"can_#{entity.action}?"
        {name, to_string(entity.action), entity.public?}
      end)

    calcs_from_batch =
      Enum.map(batch_actions, fn action ->
        {:"can_#{action}?", to_string(action), true}
      end)

    all_calcs = calcs_from_entities ++ calcs_from_batch

    # Validate that all referenced actions exist on the resource
    defined_actions =
      dsl_state
      |> Transformer.get_entities([:actions])
      |> MapSet.new(& &1.name)

    for {_name, action_str, _public?} <- all_calcs do
      # Every defined action name is an atom already; a name that is not one
      # cannot be defined (#143).
      action_atom = existing_atom(action_str)

      unless action_atom && MapSet.member?(defined_actions, action_atom) do
        available =
          defined_actions |> Enum.sort() |> Enum.map_join(", ", &":#{&1}")

        raise Spark.Error.DslError,
          module: resource,
          path: [:ash_grant, :can_perform_actions],
          message: """
          Action :#{action_str} does not exist on #{inspect(resource)}.

          Available actions: #{available}
          """
      end
    end

    # Add each calculation
    Enum.reduce_while(all_calcs, {:ok, dsl_state}, fn {name, action, public?}, {:ok, acc} ->
      case Ash.Resource.Builder.add_new_calculation(
             acc,
             name,
             :boolean,
             {AshGrant.Calculation.CanPerform, [action: action, resource: resource]},
             public?: public?
           ) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end

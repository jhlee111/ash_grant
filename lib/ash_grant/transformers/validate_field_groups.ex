defmodule AshGrant.Transformers.ValidateFieldGroups do
  @moduledoc """
  Validates field group definitions at compile time.

  Checks for:
  - Duplicate field group names
  - References to undefined parent field groups
  - Circular inheritance chains
  - mask fields without mask_with function
  - `deny_fields_by_default true` on a resource with no field group
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    field_groups = get_field_group_entities(dsl_state)

    # Only the resource's own `true` is known here: the domain cannot be read from a
    # transformer, so ValidateDenyFieldsByDefault covers inherited values.
    if field_groups == [] and
         Transformer.get_option(dsl_state, [:ash_grant], :deny_fields_by_default) == true do
      dsl_state
      |> Transformer.get_persisted(:module)
      |> AshGrant.Verifiers.ValidateDenyFieldsByDefault.error()
      |> raise()
    end

    if field_groups != [] do
      resource = Transformer.get_persisted(dsl_state, :module)
      names = Enum.map(field_groups, & &1.name)

      validate_no_duplicates!(field_groups, names, resource)
      validate_parents_exist!(field_groups, names, resource)
      validate_no_cycles!(field_groups, resource)
      validate_mask_config!(field_groups, resource)
    end

    {:ok, dsl_state}
  end

  defp get_field_group_entities(dsl_state) do
    Transformer.get_entities(dsl_state, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.FieldGroup{}, &1))
  end

  defp validate_no_duplicates!(field_groups, _names, resource) do
    names = Enum.map(field_groups, & &1.name)
    dupes = names -- Enum.uniq(names)

    if dupes != [] do
      raise Spark.Error.DslError,
        module: resource,
        path: [:ash_grant, :field_group],
        message: "Duplicate field group names: #{inspect(Enum.uniq(dupes))}"
    end
  end

  defp validate_parents_exist!(field_groups, valid_names, resource) do
    for fg <- field_groups, parents = fg.inherits || [], parent <- parents do
      unless parent in valid_names do
        raise Spark.Error.DslError,
          module: resource,
          path: [:ash_grant, :field_group, fg.name],
          message:
            "Field group #{inspect(fg.name)} inherits from #{inspect(parent)}, " <>
              "but no field group named #{inspect(parent)} exists"
      end
    end
  end

  defp validate_no_cycles!(field_groups, resource) do
    fg_map = Map.new(field_groups, &{&1.name, &1.inherits || []})

    for fg <- field_groups do
      case detect_cycle(fg.name, fg_map, []) do
        nil ->
          :ok

        cycle_path ->
          path_str = cycle_path |> Enum.reverse() |> Enum.map_join(" -> ", &inspect/1)

          raise Spark.Error.DslError,
            module: resource,
            path: [:ash_grant, :field_group, fg.name],
            message: "Circular field group inheritance detected: #{path_str}"
      end
    end
  end

  defp detect_cycle(name, fg_map, visited) do
    if name in visited do
      [name | visited]
    else
      parents = Map.get(fg_map, name, [])
      Enum.find_value(parents, fn parent -> detect_cycle(parent, fg_map, [name | visited]) end)
    end
  end

  defp validate_mask_config!(field_groups, resource) do
    for fg <- field_groups do
      if fg.mask != nil and fg.mask != [] and fg.mask_with == nil do
        raise Spark.Error.DslError,
          module: resource,
          path: [:ash_grant, :field_group, fg.name],
          message:
            "Field group #{inspect(fg.name)} has mask fields #{inspect(fg.mask)} " <>
              "but no mask_with function is configured"
      end
    end
  end
end

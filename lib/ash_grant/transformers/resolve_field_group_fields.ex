defmodule AshGrant.Transformers.ResolveFieldGroupFields do
  @moduledoc """
  Resolves `:all` and deprecated `[:*]` wildcard in field group `fields` to concrete attribute names.

  When a field group uses `:all` as its fields value, this transformer expands it
  to all public resource attributes, then removes any fields listed in the `except`
  option.

  ## Examples

      # Resolves to all attributes
      field_group :everything, :all

      # Resolves to all attributes except :salary and :ssn
      field_group :public, :all, except: [:salary, :ssn]

  ## Deprecation

  The `[:*]` syntax is deprecated in favor of `:all` and will be removed in v1.0.0.
  Using `[:*]` emits a compile-time warning and is treated as `:all` internally.

  ## Validations

  - `except` without `:all` (or deprecated `[:*]`) raises a compile error
  - Fields in `except` that don't exist as resource attributes raise a compile error
  - Masked fields that appear in `except` raise a compile error

  This transformer must run BEFORE `ValidateFieldGroups` so that resolved fields
  are validated normally by downstream transformers.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def before?(AshGrant.Transformers.ValidateFieldGroups), do: true
  def before?(_), do: false

  @impl true
  def after?(AshGrant.Transformers.ValidateScopes), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    field_groups = get_field_group_entities(dsl_state)

    if field_groups == [] do
      {:ok, dsl_state}
    else
      resource = Transformer.get_persisted(dsl_state, :module)
      all_attr_names = get_attribute_names(dsl_state)

      Enum.reduce_while(field_groups, {:ok, dsl_state}, fn fg, {:ok, acc} ->
        apply_resolution(acc, fg, all_attr_names, resource)
      end)
    end
  end

  defp apply_resolution(dsl_state, fg, all_attr_names, resource) do
    case resolve_field_group(fg, all_attr_names, resource) do
      {:ok, nil} ->
        {:cont, {:ok, dsl_state}}

      {:ok, resolved_fg} ->
        {:cont, {:ok, replace_field_group(dsl_state, fg.name, resolved_fg)}}

      {:error, message} ->
        {:halt, {:error, dsl_error(resource, fg.name, message)}}
    end
  end

  # New syntax: fields: :all, except: [...]
  defp resolve_field_group(%{fields: :all, except: except} = fg, all_attr_names, resource)
       when is_list(except) and except != [] do
    validate_except_fields_exist!(except, all_attr_names, fg.name, resource)
    validate_mask_not_in_except!(fg, resource)
    resolved_fields = all_attr_names -- except
    {:ok, %{fg | fields: resolved_fields, except: except}}
  end

  # New syntax: fields: :all (no except)
  defp resolve_field_group(%{fields: :all} = fg, all_attr_names, _resource) do
    {:ok, %{fg | fields: all_attr_names}}
  end

  # Deprecated syntax: fields: [:*], except: [...]
  defp resolve_field_group(%{fields: [:*], except: except} = fg, all_attr_names, resource)
       when is_list(except) and except != [] do
    emit_deprecation_warning(fg.name, resource)
    validate_except_fields_exist!(except, all_attr_names, fg.name, resource)
    validate_mask_not_in_except!(fg, resource)
    resolved_fields = all_attr_names -- except
    {:ok, %{fg | fields: resolved_fields, except: except}}
  end

  # Deprecated syntax: fields: [:*] (no except)
  defp resolve_field_group(%{fields: [:*]} = fg, all_attr_names, resource) do
    emit_deprecation_warning(fg.name, resource)
    {:ok, %{fg | fields: all_attr_names}}
  end

  # except with non-wildcard fields is an error
  defp resolve_field_group(%{except: except}, _all_attr_names, _resource)
       when is_list(except) and except != [] do
    {:error,
     "The `except` option is only valid when `fields` is `:all`. " <>
       "Use `:all` as the fields value or remove the `except` option."}
  end

  # No resolution needed
  defp resolve_field_group(_fg, _all_attr_names, _resource) do
    {:ok, nil}
  end

  defp emit_deprecation_warning(group_name, resource) do
    IO.warn("""
    AshGrant: field_group #{inspect(group_name)} uses deprecated [:*] syntax in #{inspect(resource)}.

    Replace [:*] with :always"
        field_group #{inspect(group_name)}, :all
        field_group #{inspect(group_name)}, :all, except: [:field1, :field2]

    The [:*] syntax will be removed in v1.0.0.
    """)
  end

  defp validate_except_fields_exist!(except, all_attr_names, group_name, _resource) do
    unknown = except -- all_attr_names

    if unknown != [] do
      raise Spark.Error.DslError,
        path: [:ash_grant, :field_group, group_name],
        message:
          "Field group #{inspect(group_name)} has `except` fields that are not " <>
            "resource attributes: #{inspect(unknown)}"
    end
  end

  defp validate_mask_not_in_except!(%{mask: mask, except: except} = fg, _resource)
       when is_list(mask) and mask != [] do
    masked_in_except = Enum.filter(mask, &(&1 in except))

    if masked_in_except != [] do
      raise Spark.Error.DslError,
        path: [:ash_grant, :field_group, fg.name],
        message:
          "Field group #{inspect(fg.name)} has masked fields #{inspect(masked_in_except)} " <>
            "that are also in `except`. Masked fields must be visible (not excluded)."
    end
  end

  defp validate_mask_not_in_except!(_fg, _resource), do: :ok

  defp replace_field_group(dsl_state, name, resolved_fg) do
    matcher = fn entity ->
      match?(%AshGrant.Dsl.FieldGroup{}, entity) and entity.name == name
    end

    Transformer.replace_entity(dsl_state, [:ash_grant], resolved_fg, matcher)
  end

  defp dsl_error(resource, group_name, message) do
    Spark.Error.DslError.exception(
      module: resource,
      path: [:ash_grant, :field_group, group_name],
      message: message
    )
  end

  defp get_field_group_entities(dsl_state) do
    Transformer.get_entities(dsl_state, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.FieldGroup{}, &1))
  end

  defp get_attribute_names(dsl_state) do
    Ash.Resource.Info.attributes(dsl_state)
    |> Enum.map(& &1.name)
  end
end

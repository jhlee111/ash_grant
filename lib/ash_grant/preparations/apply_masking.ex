defmodule AshGrant.Preparations.ApplyMasking do
  @moduledoc """
  Ash Resource Preparation that applies field masking to read results.

  When a field group defines `mask` and `mask_with`, this preparation replaces
  visible field values with masked versions for actors whose field group level
  specifies masking for those fields.

  Masking follows allow-wins semantics: if any of the actor's field groups
  provides unmasked access to a field, the field is not masked.

  ## How It Works

  1. The preparation adds an `after_action` hook to the query
  2. After records are fetched (but before field restriction), the hook:
     - Resolves the actor's field groups from permissions
     - Determines which fields should be masked (allow-wins)
     - Replaces visible field values with masked values
  3. Ash's `restrict_field_access` then runs, hiding truly forbidden fields
  """

  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn query, results ->
      {:ok, apply_masking(results, query)}
    end)
  end

  defp apply_masking(results, query) when is_list(results) do
    actor = query.context[:private][:actor]
    resource = query.resource

    if actor == nil do
      results
    else
      case compute_masked_fields(actor, resource, query) do
        masked when map_size(masked) == 0 -> results
        masked -> Enum.map(results, &mask_record(&1, masked))
      end
    end
  end

  defp compute_masked_fields(actor, resource, query) do
    resolver = AshGrant.Info.resolver(resource)
    resource_name = AshGrant.Info.resource_name(resource)
    action_name = to_string(query.action.name)

    context = %{
      actor: actor,
      resource: resource,
      action: query.action,
      tenant: query.tenant
    }

    permissions = resolve_permissions(resolver, actor, context)

    actor_field_groups =
      AshGrant.Evaluator.get_all_field_groups(permissions, resource_name, action_name)

    if actor_field_groups == [] do
      # No field groups in permissions — no masking applies
      %{}
    else
      resolve_masking(resource, actor_field_groups)
    end
  end

  # Determines which fields should be masked based on allow-wins semantics.
  # A field is masked only if ALL actor field groups that include it also mask it.
  # If ANY group provides unmasked access, the field is not masked.
  defp resolve_masking(resource, actor_groups) do
    resolved_groups = Enum.flat_map(actor_groups, &resolve_group(resource, &1))

    # Collect all masked fields from all groups
    all_masked =
      resolved_groups
      |> Enum.flat_map(fn {_name, resolved} -> Map.to_list(resolved.masked_fields) end)
      |> Map.new()

    # Apply allow-wins: if ANY group includes the field WITHOUT masking, remove it
    Enum.reduce(all_masked, %{}, fn {field, mask_fn}, acc ->
      unmasked_by_any_group? =
        Enum.any?(resolved_groups, fn {_name, resolved} ->
          field in resolved.fields and not Map.has_key?(resolved.masked_fields, field)
        end)

      if unmasked_by_any_group? do
        acc
      else
        Map.put(acc, field, mask_fn)
      end
    end)
  end

  defp resolve_group(resource, group_name) do
    case to_existing_group_atom(group_name) do
      {:ok, group_atom} -> resolve_field_group(resource, group_atom)
      :error -> []
    end
  end

  defp resolve_field_group(resource, group_atom) do
    case AshGrant.Info.resolve_field_group(resource, group_atom) do
      nil -> []
      resolved -> [{group_atom, resolved}]
    end
  end

  # Convert a field group name to an existing atom without raising. Unknown
  # group names (e.g. a permission string referencing a group that was never
  # declared) become `:error` and are dropped by `resolve_masking/2` — masking
  # for the remaining, valid groups still applies. A bare `String.to_existing_atom/1`
  # here would raise `ArgumentError`; rescuing it at the function boundary is
  # what previously swallowed the error and silently disabled all masking.
  defp to_existing_group_atom(name) when is_atom(name), do: {:ok, name}

  defp to_existing_group_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp to_existing_group_atom(_), do: :error

  defp mask_record(record, masked_fields) do
    Enum.reduce(masked_fields, record, fn {field, mask_fn}, rec ->
      current_value = Map.get(rec, field)

      # Only mask if the field is visible (not ForbiddenField)
      case current_value do
        %Ash.ForbiddenField{} -> rec
        _ -> Map.put(rec, field, mask_fn.(current_value, field))
      end
    end)
  end

  defp resolve_permissions(resolver, actor, context) when is_function(resolver, 2) do
    resolver.(actor, context)
  end

  defp resolve_permissions(resolver, actor, context) when is_atom(resolver) do
    resolver.resolve(actor, context)
  end
end

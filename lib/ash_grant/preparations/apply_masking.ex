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
     - Resolves the actor's field groups on each record, from RBAC and instance grants
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

    if actor == nil or results == [] or not masks_any_field?(resource) do
      results
    else
      mask_records(results, actor, resource, query)
    end
  end

  defp masks_any_field?(resource) do
    resource
    |> AshGrant.Info.field_groups()
    |> Enum.any?(&(&1.mask not in [nil, []]))
  end

  defp mask_records(results, actor, resource, query) do
    resolver = AshGrant.Info.resolver(resource)

    context = %{
      actor: actor,
      resource: resource,
      action: query.action,
      tenant: query.tenant
    }

    grants = resolve_permissions(resolver, actor, context)
    match = match_context(resource, query.action)

    group_sets =
      resolver
      |> AshGrant.Ceiling.permission_sets(actor, context, grants)
      |> Enum.map(&group_source(&1, match))

    {masked, _cache} =
      Enum.map_reduce(results, %{}, fn record, cache ->
        groups_per_set = Enum.map(group_sets, &record_groups(&1, record, match))

        case Map.fetch(cache, groups_per_set) do
          {:ok, masked_fields} ->
            {mask_record(record, masked_fields), cache}

          :error ->
            masked_fields = masked_fields_for(groups_per_set, resource)
            {mask_record(record, masked_fields), Map.put(cache, groups_per_set, masked_fields)}
        end
      end)

    masked
  end

  defp match_context(resource, action) do
    %{
      resource: resource,
      resource_name: AshGrant.Info.resource_name(resource),
      action_name: to_string(action.name),
      action_type: action.type,
      instance_key: AshGrant.Info.instance_key(resource),
      deny_fields_by_default?: AshGrant.Info.deny_fields_by_default?(resource)
    }
  end

  # The per-set inputs that do not depend on the record: the RBAC field groups,
  # and the instance grants that may add groups on individual records.
  defp group_source(permissions, match) do
    permissions = AshGrant.Evaluator.normalize_permissions(permissions)

    # Pass the action type: without it a type wildcard (`@read`) grant is
    # skipped, and the fields its group masks come back unmasked.
    rbac_groups =
      AshGrant.Evaluator.get_all_field_groups(
        permissions,
        match.resource_name,
        match.action_name,
        match.action_type,
        deny_fields_by_default: match.deny_fields_by_default?
      )

    rbac_matches = Enum.filter(permissions, &rbac_match?(&1, match))
    denied? = Enum.any?(rbac_matches, &AshGrant.Permission.deny?/1)

    rbac_unrestricted? =
      not match.deny_fields_by_default? and
        Enum.any?(rbac_matches, &(not AshGrant.Permission.deny?(&1) and is_nil(&1.field_group)))

    instance_grants =
      if denied? or rbac_unrestricted?,
        do: [],
        else: Enum.filter(permissions, &instance_match?(&1, match))

    %{rbac_groups: rbac_groups, unrestricted?: rbac_unrestricted?, instance: instance_grants}
  end

  defp rbac_match?(perm, match) do
    AshGrant.Permission.matches?(perm, match.resource_name, match.action_name, match.action_type)
  end

  defp instance_match?(perm, match) do
    perm.instance_id != "*" and
      AshGrant.Permission.matches_resource?(perm.resource, match.resource_name) and
      AshGrant.Permission.matches_action?(perm.action, match.action_name, match.action_type)
  end

  # `:unrestricted` when the set shows every field on the record, else the
  # field groups it opens there.
  defp record_groups(%{unrestricted?: true}, _record, _match), do: :unrestricted

  defp record_groups(source, record, match) do
    record_id = record |> Map.get(match.instance_key) |> to_string()
    on_record = Enum.filter(source.instance, &(&1.instance_id == record_id))

    cond do
      Enum.any?(on_record, &AshGrant.Permission.deny?/1) ->
        Enum.sort(source.rbac_groups)

      not match.deny_fields_by_default? and Enum.any?(on_record, &is_nil(&1.field_group)) ->
        :unrestricted

      true ->
        on_record
        |> Enum.map(& &1.field_group)
        |> Enum.reject(&is_nil/1)
        |> Enum.concat(source.rbac_groups)
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  # A field masked by either the grants or the ceiling stays masked. A set that
  # opens no group (unrestricted, or no visible group field under
  # deny_fields_by_default) has no field to mask.
  defp masked_fields_for(groups_per_set, resource) do
    groups_per_set
    |> Enum.reject(&(&1 in [:unrestricted, []]))
    |> Enum.map(&resolve_masking(resource, &1))
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
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

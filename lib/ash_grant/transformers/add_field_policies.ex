defmodule AshGrant.Transformers.AddFieldPolicies do
  @moduledoc """
  Auto-generates Ash `field_policies` from `field_group` definitions.

  When `default_field_policies: true` is set, generates field policy entries
  for each field group's direct fields using `AshGrant.FieldCheck`.

  Each field group's **direct fields** (not inherited) get a `field_policy` with
  the corresponding `AshGrant.FieldCheck`. A catch-all policy ensures fields
  not in any group remain accessible.

  ## Generated Structure

  For field groups:

      field_group :public, [:name, :department]
      field_group :sensitive, [:phone, :address], inherits: [:public]
      field_group :confidential, [:salary, :email], inherits: [:sensitive]

  Generates:

      field_policies do
        field_policy [:name, :department] do
          authorize_if AshGrant.field_check(:public)
        end

        field_policy [:phone, :address] do
          authorize_if AshGrant.field_check(:sensitive)
        end

        field_policy [:salary, :email] do
          authorize_if AshGrant.field_check(:confidential)
        end

        field_policy :* do
          authorize_if always()
        end
      end
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    default_fp = Transformer.get_option(dsl_state, [:ash_grant], :default_field_policies, false)
    field_groups = get_field_group_entities(dsl_state)

    if default_fp and field_groups != [] do
      add_field_policies(dsl_state, field_groups)
    else
      {:ok, dsl_state}
    end
  end

  defp add_field_policies(dsl_state, field_groups) do
    # For each field_group, create a field_policy for its DIRECT fields.
    # Deduplicate: when multiple groups use :all (or :all except:), they expand
    # to overlapping attribute lists. Each field must appear in exactly one
    # field_policy to avoid Ash's "all must pass" semantics causing false denials.
    # Earlier groups in DSL order win; later groups get the remaining fields.
    #
    # Filter out fields that are not valid field policy targets (primary keys,
    # private attributes). Ash only allows non-PK, public attributes, calculations,
    # and aggregates in field policies.
    valid_fields = valid_field_policy_targets(dsl_state)

    {dsl_state, _seen} =
      Enum.reduce(field_groups, {dsl_state, MapSet.new()}, fn fg, {acc, seen} ->
        all_fields = fg.fields || []
        all_fields = Enum.filter(all_fields, &(&1 in valid_fields))
        unique_fields = Enum.reject(all_fields, &MapSet.member?(seen, &1))
        new_seen = MapSet.union(seen, MapSet.new(all_fields))

        if unique_fields != [] do
          field_policy = build_field_policy(fg.name, unique_fields)
          {Transformer.add_entity(acc, [:field_policies], field_policy), new_seen}
        else
          {acc, new_seen}
        end
      end)

    # Add catch-all: field_policy :* -> authorize_if always()
    catch_all = %Ash.Policy.FieldPolicy{
      __identifier__: System.unique_integer(),
      fields: [:*],
      bypass?: false,
      condition: [],
      policies: [
        %Ash.Policy.Check{
          type: :authorize_if,
          check_module: Ash.Policy.Check.Static,
          check: {Ash.Policy.Check.Static, [result: true]},
          check_opts: [result: true]
        }
      ]
    }

    dsl_state = Transformer.add_entity(dsl_state, [:field_policies], catch_all)

    # Rebuild the field-to-policy cache since CacheFieldPolicies may have
    # already run before our transformer (it belongs to Ash.Policy.Authorizer).
    dsl_state = rebuild_field_policy_cache(dsl_state)

    {:ok, dsl_state}
  end

  defp build_field_policy(group_name, fields) do
    # `ash_field_policy?: true, access_type: :filter` are normally injected by
    # `Ash.Policy.FieldPolicy.transform/1` for checks declared via the field_policy
    # DSL. We build the struct manually (bypassing that transform), so we set them
    # here — without `access_type: :filter` a FilterCheck is treated as
    # non-filterable and Ash raises "partial filter for a field policy".
    opts = [field_group: group_name, ash_field_policy?: true, access_type: :filter]

    %Ash.Policy.FieldPolicy{
      __identifier__: System.unique_integer(),
      fields: fields,
      bypass?: false,
      condition: [],
      policies: [
        %Ash.Policy.Check{
          type: :authorize_if,
          check_module: AshGrant.FieldFilterCheck,
          check: {AshGrant.FieldFilterCheck, opts},
          check_opts: opts
        }
      ]
    }
  end

  # Rebuild the :fields_to_field_policies persisted cache.
  # This replicates the logic from Ash.Policy.Authorizer.Transformers.CacheFieldPolicies
  # because that transformer runs within the Authorizer extension and may execute
  # before our AshGrant extension transformer adds field policies.
  defp rebuild_field_policy_cache(dsl_state) do
    all_field_policies =
      Transformer.get_entities(dsl_state, [:field_policies])

    fields_to_field_policies =
      all_field_policies
      |> Enum.reduce(%{}, fn field_policy, acc ->
        field_policy.fields
        |> Enum.reduce(acc, fn field, acc ->
          Map.update(acc, field, [field_policy], &(&1 ++ [field_policy]))
        end)
      end)

    Transformer.persist(dsl_state, :fields_to_field_policies, fields_to_field_policies)
  end

  defp valid_field_policy_targets(dsl_state) do
    attrs =
      Ash.Resource.Info.attributes(dsl_state)
      |> Enum.filter(fn attr -> attr.public? and not attr.primary_key? end)
      |> Enum.map(& &1.name)

    calcs =
      Ash.Resource.Info.calculations(dsl_state)
      |> Enum.filter(& &1.public?)
      |> Enum.map(& &1.name)

    aggs =
      Ash.Resource.Info.aggregates(dsl_state)
      |> Enum.filter(& &1.public?)
      |> Enum.map(& &1.name)

    MapSet.new(attrs ++ calcs ++ aggs)
  end

  defp get_field_group_entities(dsl_state) do
    Transformer.get_entities(dsl_state, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.FieldGroup{}, &1))
  end
end

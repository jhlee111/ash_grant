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
    # For each field_group, create a field_policy for its DIRECT fields
    dsl_state =
      Enum.reduce(field_groups, dsl_state, fn fg, acc ->
        direct_fields = fg.fields || []

        if direct_fields != [] do
          field_policy = %Ash.Policy.FieldPolicy{
            __identifier__: System.unique_integer(),
            fields: direct_fields,
            bypass?: false,
            condition: [],
            policies: [
              %Ash.Policy.Check{
                type: :authorize_if,
                check_module: AshGrant.FieldCheck,
                check: {AshGrant.FieldCheck, [field_group: fg.name]},
                check_opts: [field_group: fg.name]
              }
            ]
          }

          Transformer.add_entity(acc, [:field_policies], field_policy)
        else
          acc
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

  defp get_field_group_entities(dsl_state) do
    Transformer.get_entities(dsl_state, [:ash_grant])
    |> Enum.filter(&match?(%AshGrant.Dsl.FieldGroup{}, &1))
  end
end

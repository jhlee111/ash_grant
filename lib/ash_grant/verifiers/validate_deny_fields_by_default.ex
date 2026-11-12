defmodule AshGrant.Verifiers.ValidateDenyFieldsByDefault do
  @moduledoc """
  Spark DSL verifier that reports a resource with `deny_fields_by_default` in
  effect but no `field_group`, where no grant could ever show a field.

  It reads the effective value the way `AshGrant.Info.deny_fields_by_default?/1`
  does, so a value inherited from the domain or app config is checked too. Spark
  reports verifier errors as compile warnings; an explicit resource-level `true`
  is raised as a compile error by `AshGrant.Transformers.ValidateFieldGroups`.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  @spec verify(dsl_state :: map()) :: :ok | {:error, Spark.Error.DslError.t()}
  def verify(dsl_state) do
    effective? =
      AshGrant.Info.resolve_deny_fields_by_default(
        Verifier.get_option(dsl_state, [:ash_grant], :deny_fields_by_default),
        AshGrant.Info.domain_deny_fields_by_default(Verifier.get_persisted(dsl_state, :domain)),
        Application.get_env(:ash_grant, :deny_fields_by_default)
      )

    if effective? and not field_groups?(dsl_state) do
      {:error, error(Verifier.get_persisted(dsl_state, :module))}
    else
      :ok
    end
  end

  @doc false
  @spec error(module()) :: Spark.Error.DslError.t()
  def error(resource) do
    Spark.Error.DslError.exception(
      module: resource,
      path: [:ash_grant, :deny_fields_by_default],
      message: """
      deny_fields_by_default is on for #{inspect(resource)}, but it defines no field_group,
      so no grant can show any of its fields.

      Add a field group, for example:

          ash_grant do
            field_group :public, :all
          end

      Or turn the option off for this resource:

          ash_grant do
            deny_fields_by_default false
          end
      """
    )
  end

  defp field_groups?(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:ash_grant])
    |> Enum.any?(&match?(%AshGrant.Dsl.FieldGroup{}, &1))
  end
end

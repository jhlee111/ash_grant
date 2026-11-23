defmodule AshGrant.Transformers.ValidatePolicyAuthorizer do
  @moduledoc """
  Spark DSL transformer that fails compilation when AshGrant generates policies
  for a resource that does not use `Ash.Policy.Authorizer`.

  `default_policies` and `default_field_policies` only take effect through
  `Ash.Policy.Authorizer`. Without it in the resource's `authorizers:` option,
  the generated policies never run and every actor is authorized. A
  `default_field_policies` inherited from `config :ash_grant` is checked too.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl Spark.Dsl.Transformer
  @spec transform(dsl_state :: map()) :: {:ok, map()} | {:error, DslError.t()}
  def transform(dsl_state) do
    case generated_policy_option(dsl_state) do
      nil ->
        {:ok, dsl_state}

      {option, source} ->
        if Ash.Policy.Authorizer in Transformer.get_persisted(dsl_state, :authorizers, []) do
          {:ok, dsl_state}
        else
          {:error, missing_authorizer_error(dsl_state, option, source)}
        end
    end
  end

  @spec generated_policy_option(dsl_state :: map()) ::
          {atom(), :resource | :app_config} | nil
  defp generated_policy_option(dsl_state) do
    cond do
      Transformer.get_option(dsl_state, [:ash_grant], :default_policies, false) != false ->
        {:default_policies, :resource}

      not AshGrant.Info.dsl_default_field_policies(dsl_state) ->
        nil

      is_nil(Transformer.get_option(dsl_state, [:ash_grant], :default_field_policies)) ->
        {:default_field_policies, :app_config}

      true ->
        {:default_field_policies, :resource}
    end
  end

  @spec missing_authorizer_error(dsl_state :: map(), atom(), :resource | :app_config) ::
          DslError.t()
  defp missing_authorizer_error(dsl_state, option, source) do
    resource = Transformer.get_persisted(dsl_state, :module)

    DslError.exception(
      module: resource,
      path: [:ash_grant, option],
      message: """
      #{inspect(resource)} #{describe_source(option, source)} but does not use Ash.Policy.Authorizer.

      The generated policies would never run, so every actor would be authorized.
      Add the authorizer to the resource options:

          use Ash.Resource,
            extensions: [AshGrant],
            authorizers: [Ash.Policy.Authorizer]
      #{opt_out_hint(option, source)}\
      """
    )
  end

  defp describe_source(option, :resource), do: "sets `#{option}`"

  defp describe_source(option, :app_config),
    do: "inherits `#{option}` from `config :ash_grant`"

  defp opt_out_hint(_option, :resource), do: ""

  defp opt_out_hint(option, :app_config) do
    """

    Or opt this resource out:

        ash_grant do
          #{option} false
        end
    """
  end
end

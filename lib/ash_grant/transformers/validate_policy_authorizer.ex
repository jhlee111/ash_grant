defmodule AshGrant.Transformers.ValidatePolicyAuthorizer do
  @moduledoc """
  Spark DSL transformer that fails compilation when AshGrant generates policies
  for a resource that does not use `Ash.Policy.Authorizer`.

  `default_policies` and `default_field_policies` only take effect through
  `Ash.Policy.Authorizer`. Without it in the resource's `authorizers:` option,
  the generated policies never run and every actor is authorized.
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

      option ->
        if Ash.Policy.Authorizer in Transformer.get_persisted(dsl_state, :authorizers, []) do
          {:ok, dsl_state}
        else
          {:error, missing_authorizer_error(dsl_state, option)}
        end
    end
  end

  @spec generated_policy_option(dsl_state :: map()) :: atom() | nil
  defp generated_policy_option(dsl_state) do
    cond do
      Transformer.get_option(dsl_state, [:ash_grant], :default_policies, false) != false ->
        :default_policies

      Transformer.get_option(dsl_state, [:ash_grant], :default_field_policies, false) ->
        :default_field_policies

      true ->
        nil
    end
  end

  @spec missing_authorizer_error(dsl_state :: map(), option :: atom()) ::
          DslError.t()
  defp missing_authorizer_error(dsl_state, option) do
    resource = Transformer.get_persisted(dsl_state, :module)

    DslError.exception(
      module: resource,
      path: [:ash_grant, option],
      message: """
      #{inspect(resource)} sets `#{option}` but does not use Ash.Policy.Authorizer.

      The generated policies would never run, so every actor would be authorized.
      Add the authorizer to the resource options:

          use Ash.Resource,
            extensions: [AshGrant],
            authorizers: [Ash.Policy.Authorizer]
      """
    )
  end
end

defmodule AshGrant.Transformers.AddDefaultPolicies do
  @moduledoc """
  Spark DSL transformer that auto-generates policies when `default_policies` is enabled.

  This transformer runs at compile time and automatically generates the standard
  AshGrant policy configuration, reducing boilerplate for common use cases.

  ## Configuration

  Enable in your resource's `ash_grant` block:

      ash_grant do
        resolver MyApp.PermissionResolver
        default_policies true  # or :all, :read, :write
      end

  ## Options

  | Value | Description |
  |-------|-------------|
  | `false` | No policies generated (default) |
  | `true` or `:all` | Generate both read and write policies |
  | `:read` | Only generate `filter_check()` policy for read actions |
  | `:write` | Only generate `check()` policy for write actions |

  ## Generated Policies

  When `default_policies: true` or `:all`:

      policies do
        policy action_type(:read) do
          authorize_if AshGrant.filter_check()
        end

        policy action_type([:create, :update, :destroy]) do
          authorize_if AshGrant.check()
        end
      end

  ## Implementation Details

  This transformer:
  - Runs **before** `Ash.Policy.Authorizer` to inject policies
  - Uses `Spark.Dsl.Transformer.add_entity/3` to add policy entities
  - Sets appropriate `access_type` (`:filter` for read, `:strict` for write)

  ## See Also

  - `AshGrant.Check` - SimpleCheck for write actions
  - `AshGrant.FilterCheck` - FilterCheck for read actions
  - `AshGrant.Info.default_policies/1` - Query the setting at runtime
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(Ash.Policy.Authorizer), do: false
  def after?(_), do: true

  @impl true
  def before?(Ash.Policy.Authorizer), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    default_policies = Transformer.get_option(dsl_state, [:ash_grant], :default_policies, false)

    case default_policies do
      false ->
        {:ok, dsl_state}

      value when value in [true, :all] ->
        with {:ok, dsl_state} <- add_read_policy(dsl_state),
             {:ok, dsl_state} <- add_write_policy(dsl_state) do
          {:ok, dsl_state}
        end

      :read ->
        add_read_policy(dsl_state)

      :write ->
        add_write_policy(dsl_state)
    end
  end

  defp add_read_policy(dsl_state) do
    read_policy = %Ash.Policy.Policy{
      bypass?: false,
      access_type: :filter,
      condition: [{Ash.Policy.Check.ActionType, type: [:read]}],
      policies: [
        %Ash.Policy.Check{
          type: :authorize_if,
          check_module: AshGrant.FilterCheck,
          check: {AshGrant.FilterCheck, []},
          check_opts: []
        }
      ]
    }

    {:ok, Transformer.add_entity(dsl_state, [:policies], read_policy)}
  end

  defp add_write_policy(dsl_state) do
    write_policy = %Ash.Policy.Policy{
      bypass?: false,
      access_type: :strict,
      condition: [{Ash.Policy.Check.ActionType, type: [:create, :update, :destroy]}],
      policies: [
        %Ash.Policy.Check{
          type: :authorize_if,
          check_module: AshGrant.Check,
          check: {AshGrant.Check, []},
          check_opts: []
        }
      ]
    }

    {:ok, Transformer.add_entity(dsl_state, [:policies], write_policy)}
  end
end

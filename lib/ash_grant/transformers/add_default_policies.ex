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
  | `true` or `:all` | Generate read, write, and generic action policies |
  | `:read` | Only generate `filter_check()` policy for read actions |
  | `:write` | Only generate `check()` policy for write and generic actions |

  ## Generated Policies

  When `default_policies: true` or `:all`:

      policies do
        policy action_type(:read) do
          authorize_if AshGrant.filter_check()
        end

        policy action_type([:create, :update, :destroy]) do
          authorize_if AshGrant.check()
        end

        policy action_type(:action) do
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
        {:ok, insert_generated(dsl_state, [read_policy(), write_policy(), generic_action_policy()])}

      :read ->
        {:ok, insert_generated(dsl_state, [read_policy()])}

      :write ->
        {:ok, insert_generated(dsl_state, [write_policy()])}
    end
  end

  # Inserts the generated policies after any user-declared `bypass` entries,
  # and before any user-declared non-bypass policies. A bypass that short-circuits
  # (for example, `AshAuthentication.Checks.AshAuthenticationInteraction` on a
  # user resource) must get a chance to allow before the generated strict policies
  # can deny. `Transformer.add_entity/3` prepends, which would place the generated
  # policies ahead of the bypass and make every action with no actor fail.
  defp insert_generated(dsl_state, generated) do
    existing = Transformer.get_entities(dsl_state, [:policies])
    {bypasses, non_bypasses} = Enum.split_with(existing, & &1.bypass?)
    set_policies(dsl_state, bypasses ++ generated ++ non_bypasses)
  end

  defp set_policies(dsl_state, policies) do
    Map.update(dsl_state, [:policies], %{entities: policies, opts: []}, fn config ->
      Map.put(config, :entities, policies)
    end)
  end

  defp read_policy do
    %Ash.Policy.Policy{
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
  end

  defp write_policy do
    %Ash.Policy.Policy{
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
  end

  defp generic_action_policy do
    %Ash.Policy.Policy{
      bypass?: false,
      access_type: :strict,
      condition: [{Ash.Policy.Check.ActionType, type: [:action]}],
      policies: [
        %Ash.Policy.Check{
          type: :authorize_if,
          check_module: AshGrant.Check,
          check: {AshGrant.Check, []},
          check_opts: []
        }
      ]
    }
  end
end

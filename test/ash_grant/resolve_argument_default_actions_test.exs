defmodule AshGrant.ResolveArgumentDefaultActionsTest do
  @moduledoc """
  `resolve_argument` must wire actions declared through `defaults [...]`, not
  only explicitly declared ones.

  Default actions become entities in `Ash.Resource.Transformers.SetPrimaryActions`.
  `AddArgumentResolvers` used to declare no ordering against it, so whether it
  saw the default actions depended on Spark's tie-break between unordered
  transformers. That tie-break shifted on Ash 3.36+, the transformer ran first,
  and the argument and change were silently not injected. The runtime symptom
  (argument scopes Forbidden) is covered in `ResolveArgumentRuntimeTest`; these
  tests pin the compile-time cause.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Changes.ResolveArgument
  alias AshGrant.Test.DomainArgPost
  alias AshGrant.Transformers.AddArgumentResolvers

  defmodule DefaultsForActions do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshGrant]

    ash_grant do
      resolver(fn _, _ -> [] end)
      resource_name("defaults_for_actions")
      scope(:at_own_unit, expr(^arg(:center_id) == ^actor(:org_id)))
      # Names a `defaults` action: raises at compile time if the transformer
      # runs before the default actions exist.
      resolve_argument(:center_id, from_path: [:org_id], for_actions: [:update])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defp wired?(resource, action_name, arg_name) do
    action = Ash.Resource.Info.action(resource, action_name)

    has_argument? = Enum.any?(action.arguments, &(&1.name == arg_name))

    has_change? =
      Enum.any?(action.changes, fn
        %Ash.Resource.Change{change: {ResolveArgument, opts}} -> opts[:name] == arg_name
        _ -> false
      end)

    has_argument? and has_change?
  end

  test "every default write action gets the argument and the change" do
    for action <- [:create, :update, :destroy] do
      assert wired?(DomainArgPost, action, :center_id),
             "default #{action} action is missing the resolve_argument wiring"
    end
  end

  test "for_actions can name a default action, and only that action is wired" do
    assert wired?(DefaultsForActions, :update, :center_id)
    refute wired?(DefaultsForActions, :create, :center_id)
    refute wired?(DefaultsForActions, :destroy, :center_id)
  end

  test "Spark orders AddArgumentResolvers after SetPrimaryActions" do
    sorted =
      DomainArgPost
      |> Spark.extensions()
      |> Enum.flat_map(& &1.transformers())
      |> Spark.Dsl.Transformer.sort()

    primary = Enum.find_index(sorted, &(&1 == Ash.Resource.Transformers.SetPrimaryActions))
    resolvers = Enum.find_index(sorted, &(&1 == AddArgumentResolvers))

    assert primary && resolvers
    assert resolvers > primary
  end
end

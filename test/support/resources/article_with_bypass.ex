defmodule AshGrant.Test.ArticleBypassCheck do
  @moduledoc false
  # Stand-in for `AshAuthentication.Checks.AshAuthenticationInteraction`.
  # Passes when the subject context carries `stub_bypass: true`, which lets a
  # test exercise the "sign-in happens before there is an actor" path without
  # pulling AshAuthentication into the dependency tree.
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "stub auth-interaction bypass"

  @impl true
  def match?(_actor, %{subject: subject}, _opts) do
    subject
    |> Map.get(:context)
    |> Kernel.||(%{})
    |> Map.get(:stub_bypass, false) == true
  end
end

defmodule AshGrant.Test.ArticleWithBypass do
  @moduledoc false
  # Combines `default_policies true` with a user-declared `bypass` entry, the
  # shape every AshAuthentication user resource ends up with.
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ets do
    private?(true)
  end

  ash_grant do
    resolver(fn _actor, _context -> [] end)
    resource_name("article_with_bypass")
    default_policies(true)
    scope(:always, true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :sign_in do
      accept([:name])
    end

    create :create do
      accept([:name])
    end
  end

  policies do
    bypass AshGrant.Test.ArticleBypassCheck do
      authorize_if(always())
    end
  end
end

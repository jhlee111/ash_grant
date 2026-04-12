defmodule AshGrant.Test.DomainMinimalPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.GrantDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    default_policies(true)

    # Extra scope beyond domain's :always and :own
    scope(:published, expr(status == :published))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true)

    attribute :status, :atom do
      constraints(one_of: [:draft, :published])
      default(:draft)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:title, :author_id, :status])
    end

    update :update do
      accept([:title, :status])
    end
  end
end

defmodule AshGrant.Test.CeilingPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ets do
    private?(true)
  end

  ash_grant do
    resolver(AshGrant.Test.CeilingResolver)
    default_policies(true)
    default_field_policies(true)
    resource_name("ceiling_post")

    scope(:always, true)
    scope(:own, expr(author_id == ^actor(:id)))
    scope(:published, expr(status == :published))

    field_group(:summary, [:title, :status, :author_id])
    field_group(:full, [:body], inherits: [:summary])

    can_perform_actions([:update, :destroy])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:body, :string, public?: true)

    attribute :status, :atom do
      constraints(one_of: [:draft, :published])
      default(:draft)
      public?(true)
    end

    attribute(:author_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

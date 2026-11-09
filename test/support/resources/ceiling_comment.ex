defmodule AshGrant.Test.CeilingComment do
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
    resource_name("ceiling_comment")

    scope(:always, true)
    scope(:on_own_post, expr(^arg(:post_author_id) == ^actor(:id)))

    scope_through(:ceiling_post)

    resolve_argument(:post_author_id, from_path: [:ceiling_post, :author_id])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true)
  end

  relationships do
    belongs_to :ceiling_post, AshGrant.Test.CeilingPost do
      public?(true)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:body, :ceiling_post_id])
    end

    update :update do
      accept([:body])
      require_atomic?(false)
    end
  end
end

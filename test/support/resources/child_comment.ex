defmodule AshGrant.Test.ChildComment do
  @moduledoc """
  ChildComment resource for testing scope_through feature.

  Demonstrates inheriting a parent resource's (Post) instance permissions
  via the :post belongs_to relationship. When a user has `"post:post_abc:read:"`,
  they can read ChildComments where `post_id == post_abc`.
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("comments")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    resource_name("child_comment")

    scope(:always, true)
    scope(:own, expr(user_id == ^actor(:id)))

    scope_through(:post)

    can_perform_actions([:update])
  end

  policies do
    policy action_type(:read) do
      authorize_if(AshGrant.filter_check())
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(AshGrant.check())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true, allow_nil?: false)
    attribute(:user_id, :uuid, public?: true)
    attribute(:post_id, :uuid, public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :post, AshGrant.Test.Post do
      attribute_writable?(true)
      define_attribute?(false)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:body, :user_id, :post_id])
    end

    update :update do
      accept([:body])
    end
  end
end

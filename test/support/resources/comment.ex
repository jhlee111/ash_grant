defmodule AshGrant.Test.Comment do
  @moduledoc false
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
        nil ->
          []

        %{permissions: perms} ->
          perms

        %{role: :admin} ->
          ["comment:*:*:always"]

        %{role: :user} ->
          ["comment:*:read:always", "comment:*:create:always", "comment:*:delete:own"]

        _ ->
          []
      end
    end)

    resource_name("comment")

    scope(:always, true)
    scope(:own, expr(user_id == ^actor(:id)))
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if(always())
    end

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

defmodule AshGrant.Test.Feed do
  @moduledoc """
  Feed resource for testing instance_key feature.

  Demonstrates matching instance permissions against a custom field (feed_id)
  instead of the default primary key (id).
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("feeds")
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

    resource_name("feed")
    instance_key(:feed_id)

    scope(:always, true)
    scope(:published, expr(status == :published))

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
    attribute(:feed_id, :string, allow_nil?: false, public?: true)
    attribute(:title, :string, allow_nil?: false, public?: true)

    attribute :status, :atom do
      constraints(one_of: [:draft, :published])
      default(:draft)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:feed_id, :title, :status])
    end

    update :update do
      accept([:title, :status])
    end
  end
end

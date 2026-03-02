defmodule AshGrant.Test.BulkTeam do
  @moduledoc """
  Supporting resource for bulk operations testing.
  Provides the team entity for exists() scope relationship traversal.
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("bulk_test_teams")
    repo(AshGrant.TestRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :memberships, AshGrant.Test.BulkMembership do
      destination_attribute(:team_id)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

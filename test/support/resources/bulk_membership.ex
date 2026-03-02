defmodule AshGrant.Test.BulkMembership do
  @moduledoc """
  Supporting resource for bulk operations testing.
  Represents team membership for exists() scope evaluation.
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("bulk_test_memberships")
    repo(AshGrant.TestRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:user_id, :uuid, public?: true, allow_nil?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :team, AshGrant.Test.BulkTeam do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

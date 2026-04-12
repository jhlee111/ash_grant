defmodule AshGrant.Test.BulkItem do
  @moduledoc """
  Test resource for bulk operations with exists() scope.

  Reproduces the crash when `Ash.bulk_create/4` is used with a resource
  that has an `exists()` scope expression. The `team_member` scope traverses
  `team.memberships` relationship which crashes on virtual records.

  ## Scopes

  | Scope | Filter |
  |-------|--------|
  | :always | true |
  | :own | author_id == ^actor(:id) |
  | :team_member | exists(team.memberships, user_id == ^actor(:id)) |
  | :own_in_team | author_id == ^actor(:id) AND exists(team.memberships, ...) |
  | :named_team | team.name == ^actor(:team_name) (dot-path) |
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("bulk_test_items")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["item:*:*:always"]
        _ -> []
      end
    end)

    resource_name("item")

    scope(:always, true)
    scope(:own, expr(author_id == ^actor(:id)))
    scope(:team_member, [], expr(exists(team.memberships, user_id == ^actor(:id))))

    scope(
      :own_in_team,
      [],
      expr(author_id == ^actor(:id) and exists(team.memberships, user_id == ^actor(:id)))
    )

    scope(:named_team, [], expr(team.name == ^actor(:team_name)))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :team, AshGrant.Test.BulkTeam do
      public?(true)
      allow_nil?(true)
      attribute_writable?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(AshGrant.filter_check())
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(AshGrant.check())
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

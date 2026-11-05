defmodule AshGrant.Test.WriteExistsItem.LegacyScopeResolver do
  @moduledoc """
  Legacy `scope_resolver` that returns relationship-bearing filters.
  """
  @behaviour AshGrant.ScopeResolver

  import Ash.Expr

  @impl true
  def resolve("legacy_exists", _context),
    do: expr(exists(team.memberships, user_id == ^actor(:id)))

  def resolve("legacy_dot_path", _context),
    do: expr(team.name == ^actor(:team_name))

  def resolve(_scope, _context), do: false
end

defmodule AshGrant.Test.WriteExistsItem do
  @moduledoc """
  Test resource for write checks on relationship-bearing scopes that do not
  come from an inline scope without `write:`.

  Shares the `bulk_test_items` table with `AshGrant.Test.BulkItem`.

  ## Scopes

  | Scope | Filter | Write |
  |-------|--------|-------|
  | :always | true | |
  | :team_member | exists(team.memberships, user_id == ^actor(:id)) | |
  | :write_exists | author_id == ^actor(:id) | exists(team.memberships, ...) |
  | :write_exists_and_own | author_id == ^actor(:id) | exists(team.memberships, ...) and author_id == ^actor(:id) |
  | :write_dot_path | author_id == ^actor(:id) | team.name == ^actor(:team_name) |
  | "legacy_exists" | scope_resolver: exists(team.memberships, ...) | |
  | "legacy_dot_path" | scope_resolver: team.name == ^actor(:team_name) | |
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
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    scope_resolver(AshGrant.Test.WriteExistsItem.LegacyScopeResolver)
    resource_name("write_exists_item")
    default_policies(true)

    scope(:always, true)
    scope(:team_member, expr(exists(team.memberships, user_id == ^actor(:id))))

    scope(:write_exists, expr(author_id == ^actor(:id)),
      write: expr(exists(team.memberships, user_id == ^actor(:id)))
    )

    scope(:write_exists_and_own, expr(author_id == ^actor(:id)),
      write: expr(exists(team.memberships, user_id == ^actor(:id)) and author_id == ^actor(:id))
    )

    scope(:write_dot_path, expr(author_id == ^actor(:id)),
      write: expr(team.name == ^actor(:team_name))
    )
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

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

# Defined here rather than in test/support: `write:` and `scope_resolver` emit
# deprecation warnings, which fail `mix compile --warnings-as-errors` in CI.
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

defmodule AshGrant.Test.WriteExistsDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGrant.Test.WriteExistsItem)
  end
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
    domain: AshGrant.Test.WriteExistsDomain,
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

defmodule AshGrant.WritePathExistsFailOpenTest do
  @moduledoc """
  The write check must evaluate relationship-bearing scopes against the
  database, wherever the scope came from: an inline scope, its `write:`
  expression, or a legacy `scope_resolver`.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.BulkMembership
  alias AshGrant.Test.BulkTeam
  alias AshGrant.Test.WriteExistsItem

  defp actor_with(perms, attrs \\ %{}) do
    Map.merge(%{id: Ash.UUID.generate(), permissions: perms}, attrs)
  end

  defp create_team!(name) do
    BulkTeam
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!(authorize?: false)
  end

  defp create_membership!(team, user_id) do
    BulkMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: user_id})
    |> Ash.create!(authorize?: false)
  end

  defp create_item!(attrs) do
    WriteExistsItem
    |> Ash.Changeset.for_create(:create, Map.put_new(attrs, :title, "Item"))
    |> Ash.create!(authorize?: false)
  end

  defp update_item(item, actor) do
    item
    |> Ash.Changeset.for_update(:update, %{title: "Updated"})
    |> Ash.update(actor: actor)
  end

  defp destroy_item(item, actor) do
    item
    |> Ash.Changeset.for_destroy(:destroy)
    |> Ash.destroy(actor: actor)
  end

  defp perms(action, scope),
    do: ["write_exists_item:*:#{action}:#{scope}", "write_exists_item:*:read:always"]

  describe "legacy scope_resolver returning exists()" do
    test "update by an actor outside the team is forbidden" do
      item = create_item!(%{team_id: create_team!("Other").id})

      assert {:error, %Ash.Error.Forbidden{}} =
               update_item(item, actor_with(perms("update", "legacy_exists")))
    end

    test "destroy by an actor outside the team is forbidden" do
      item = create_item!(%{team_id: create_team!("Other").id})

      assert {:error, %Ash.Error.Forbidden{}} =
               destroy_item(item, actor_with(perms("destroy", "legacy_exists")))
    end

    test "update by a team member is allowed" do
      team = create_team!("Mine")
      member = actor_with(perms("update", "legacy_exists"))
      create_membership!(team, member.id)
      item = create_item!(%{team_id: team.id})

      assert {:ok, %{title: "Updated"}} = update_item(item, member)
    end
  end

  describe "legacy scope_resolver returning a dot-path" do
    test "update by an actor with no team name is forbidden" do
      item = create_item!(%{team_id: create_team!("Other").id})

      assert {:error, %Ash.Error.Forbidden{}} =
               update_item(item, actor_with(perms("update", "legacy_dot_path")))
    end

    test "update by an actor whose team name matches is allowed" do
      item = create_item!(%{team_id: create_team!("Mine").id})

      assert {:ok, _} =
               update_item(
                 item,
                 actor_with(perms("update", "legacy_dot_path"), %{team_name: "Mine"})
               )
    end
  end

  describe "inline write: expression with exists()" do
    test "update by the author outside the team is forbidden" do
      author = actor_with(perms("update", "write_exists"))
      item = create_item!(%{author_id: author.id, team_id: create_team!("Other").id})

      assert {:error, %Ash.Error.Forbidden{}} = update_item(item, author)
    end

    test "update by a team member is allowed" do
      team = create_team!("Mine")
      member = actor_with(perms("update", "write_exists"))
      create_membership!(team, member.id)
      item = create_item!(%{team_id: team.id})

      assert {:ok, %{title: "Updated"}} = update_item(item, member)
    end
  end

  describe "inline write: expression combining exists() and an attribute check" do
    test "update by the author outside the team is forbidden" do
      author = actor_with(perms("update", "write_exists_and_own"))
      item = create_item!(%{author_id: author.id, team_id: create_team!("Other").id})

      assert {:error, %Ash.Error.Forbidden{}} = update_item(item, author)
    end

    test "update by a team member who is not the author is forbidden" do
      team = create_team!("Mine")
      member = actor_with(perms("update", "write_exists_and_own"))
      create_membership!(team, member.id)
      item = create_item!(%{author_id: Ash.UUID.generate(), team_id: team.id})

      assert {:error, %Ash.Error.Forbidden{}} = update_item(item, member)
    end

    test "update by an author who is a team member is allowed" do
      team = create_team!("Mine")
      member = actor_with(perms("update", "write_exists_and_own"))
      create_membership!(team, member.id)
      item = create_item!(%{author_id: member.id, team_id: team.id})

      assert {:ok, %{title: "Updated"}} = update_item(item, member)
    end
  end

  describe "inline write: expression with a dot-path" do
    test "update by an actor with no team name is forbidden" do
      author = actor_with(perms("update", "write_dot_path"))
      item = create_item!(%{author_id: author.id, team_id: create_team!("Other").id})

      assert {:error, %Ash.Error.Forbidden{}} = update_item(item, author)
    end
  end

  describe "inline scope with exists() and no write:" do
    test "update by an actor outside the team is forbidden" do
      item = create_item!(%{team_id: create_team!("Other").id})

      assert {:error, %Ash.Error.Forbidden{}} =
               update_item(item, actor_with(perms("update", "team_member")))
    end
  end
end

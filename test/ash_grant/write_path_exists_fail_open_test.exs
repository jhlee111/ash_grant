defmodule AshGrant.WritePathExistsFailOpenTest do
  @moduledoc """
  The write check must evaluate relationship-bearing scopes against the
  database, wherever the scope came from: an inline scope, its `write:`
  expression, or a legacy `scope_resolver`.
  """
  use AshGrant.DataCase, async: true

  import Ash.Expr

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

  describe "fallback_evaluation/3" do
    test "denies a filter whose ^actor reference has no recognised shape" do
      filter = expr(fragment("? = ?", author_id, ^actor(:id)))

      context = %{resource: WriteExistsItem, tenant: nil, actor: %{id: Ash.UUID.generate()}}

      refute AshGrant.Check.fallback_evaluation(
               %{author_id: Ash.UUID.generate()},
               filter,
               context
             )
    end
  end
end

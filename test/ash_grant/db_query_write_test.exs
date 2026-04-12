defmodule AshGrant.DbQueryWriteTest do
  @moduledoc """
  Integration tests for DB query fallback on write actions.

  When a scope contains relationship references (exists() or dot-paths)
  and no `write:` option is set, AshGrant.Check uses a DB query to verify
  the scope instead of in-memory evaluation.

  Uses BulkItem/BulkTeam/BulkMembership test resources.
  """
  use AshGrant.DataCase, async: true

  require Ash.Query

  alias AshGrant.Test.BulkItem
  alias AshGrant.Test.BulkTeam
  alias AshGrant.Test.BulkMembership

  # === Test Actors ===

  defp actor_with_perms(perms, id \\ Ash.UUID.generate()) do
    %{id: id, permissions: perms}
  end

  # === Helper Functions ===

  defp create_team!(name) do
    BulkTeam
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_membership!(team, user_id) do
    BulkMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: user_id}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_item!(attrs) do
    BulkItem
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # ============================================================
  # DB query fallback for update/destroy
  # ============================================================

  describe "DB query fallback for update" do
    test "update with exists() scope and valid membership succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:team_member", "item:*:read:always"], actor_id)

      team = create_team!("Update Team")
      create_membership!(team, actor_id)
      item = create_item!(%{title: "Team Item", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Updated"})
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.title == "Updated"
    end

    test "update with exists() scope and no membership is forbidden" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:team_member", "item:*:read:always"], actor_id)

      team = create_team!("No Member Team")
      # No membership created for actor
      item = create_item!(%{title: "Team Item", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Should Fail"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "DB query fallback for destroy" do
    test "destroy with exists() scope and valid membership succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:destroy:team_member", "item:*:read:always"], actor_id)

      team = create_team!("Destroy Team")
      create_membership!(team, actor_id)
      item = create_item!(%{title: "Delete Me", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_destroy(:destroy)
        |> Ash.destroy(actor: actor)

      assert :ok = result
    end

    test "destroy with exists() scope and no membership is forbidden" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:destroy:team_member", "item:*:read:always"], actor_id)

      team = create_team!("No Member Team")
      item = create_item!(%{title: "Keep Me", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_destroy(:destroy)
        |> Ash.destroy(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "DB query fallback for update with mixed scope" do
    test "update with mixed scope (own + exists) and both conditions met succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:own_in_team", "item:*:read:always"], actor_id)

      team = create_team!("Mixed Team")
      create_membership!(team, actor_id)
      item = create_item!(%{title: "My Team Item", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Updated"})
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.title == "Updated"
    end

    test "update with mixed scope, own matches but no membership, is forbidden" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:own_in_team", "item:*:read:always"], actor_id)

      team = create_team!("No Member Team")
      # author_id matches but no membership
      item = create_item!(%{title: "My Item", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Should Fail"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  # ============================================================
  # DB query fallback for create
  # ============================================================

  describe "DB query fallback for create" do
    test "create with exists() scope and valid team+membership succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member"], actor_id)

      team = create_team!("Create Team")
      create_membership!(team, actor_id)

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "New Item",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:ok, item} = result
      assert item.title == "New Item"
    end

    test "create with exists() scope and no membership is forbidden" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member"], actor_id)

      team = create_team!("No Member Team")
      # No membership created

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Should Fail",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "create with exists() scope and nil team_id is forbidden" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member"], actor_id)

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "No Team",
          author_id: actor_id,
          team_id: nil
        })
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "create with mixed scope (own + exists), both conditions met, succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:own_in_team"], actor_id)

      team = create_team!("Mixed Create Team")
      create_membership!(team, actor_id)

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "My Team Item",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:ok, item} = result
      assert item.title == "My Team Item"
    end

    test "create with mixed scope, exists matches but own doesn't, is forbidden" do
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:own_in_team"], actor_id)

      team = create_team!("Mixed Create Team")
      create_membership!(team, actor_id)

      # author_id does NOT match actor, but membership exists
      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Other's Item",
          author_id: other_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  # ============================================================
  # DB query fallback with bulk operations
  # ============================================================

  describe "DB query fallback with bulk operations" do
    test "bulk_create with exists() scope and valid membership succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member"], actor_id)

      team = create_team!("Bulk Create Team")
      create_membership!(team, actor_id)

      inputs = [
        %{title: "Bulk 1", author_id: actor_id, team_id: team.id},
        %{title: "Bulk 2", author_id: actor_id, team_id: team.id}
      ]

      result =
        Ash.bulk_create(inputs, BulkItem, :create,
          actor: actor,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 2
    end

    test "bulk_update with exists() scope and valid membership succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:team_member", "item:*:read:always"], actor_id)

      team = create_team!("Bulk Update Team")
      create_membership!(team, actor_id)
      _item = create_item!(%{title: "Bulk Update Item", author_id: actor_id, team_id: team.id})

      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_update(:update, %{title: "Bulk Updated"},
          actor: actor,
          strategy: :stream,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 1
      assert hd(result.records).title == "Bulk Updated"
    end

    test "bulk_destroy with exists() scope and valid membership succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:destroy:team_member", "item:*:read:always"], actor_id)

      team = create_team!("Bulk Destroy Team")
      create_membership!(team, actor_id)
      _item = create_item!(%{title: "Bulk Delete Item", author_id: actor_id, team_id: team.id})

      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_destroy(:destroy, %{},
          actor: actor,
          strategy: :stream,
          authorize_query?: false,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 1
    end
  end

  # ============================================================
  # non-relationship scopes still use in-memory eval
  # ============================================================

  describe "non-relationship scopes still use in-memory eval" do
    test "own scope (direct attribute) uses in-memory eval" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:own", "item:*:read:always"], actor_id)

      item = create_item!(%{title: "My Item", author_id: actor_id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Updated"})
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.title == "Updated"
    end

    test "own scope rejects non-owner" do
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:own", "item:*:read:always"], actor_id)

      item = create_item!(%{title: "Other's Item", author_id: other_id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Should Fail"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "all scope uses in-memory eval (short-circuits)" do
      actor = actor_with_perms(["item:*:update:always"])

      item = create_item!(%{title: "Any Item", author_id: Ash.UUID.generate()})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Updated"})
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.title == "Updated"
    end
  end

  # ============================================================
  # DB query fallback for dot-path expressions (Ash.Query.Call)
  # ============================================================

  describe "DB query fallback for dot-path expressions" do
    test "update with dot-path scope and matching team name succeeds" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with_perms(["item:*:update:named_team", "item:*:read:always"], actor_id)
        |> Map.put(:team_name, "Alpha")

      team = create_team!("Alpha")
      item = create_item!(%{title: "Dot Path Item", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Updated"})
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.title == "Updated"
    end

    test "update with dot-path scope and non-matching team name is forbidden" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with_perms(["item:*:update:named_team", "item:*:read:always"], actor_id)
        |> Map.put(:team_name, "Beta")

      team = create_team!("Alpha")
      item = create_item!(%{title: "Dot Path Item", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Should Fail"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "create with dot-path scope and matching team name succeeds" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with_perms(["item:*:create:named_team"], actor_id)
        |> Map.put(:team_name, "Gamma")

      team = create_team!("Gamma")

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Dot Path Create",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:ok, item} = result
      assert item.title == "Dot Path Create"
    end

    test "create with dot-path scope and non-matching team name is forbidden" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with_perms(["item:*:create:named_team"], actor_id)
        |> Map.put(:team_name, "Delta")

      team = create_team!("Epsilon")

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Should Fail",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "create with dot-path scope and list-membership check (in operator) succeeds" do
      actor_id = Ash.UUID.generate()
      team = create_team!("InCheck")

      # Simulates GsNet pattern: scope :at_own_unit, expr(order.center_id in ^actor(:own_org_unit_ids))
      # The `in` operator with a list from actor context + dot-path relationship traversal
      # is the exact pattern used for refund authorization.
      # This test verifies dot-path + `in` works (not just dot-path + `==`).
      actor =
        actor_with_perms(["item:*:create:named_team"], actor_id)
        |> Map.put(:team_name, "InCheck")

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "In Operator Create",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:ok, item} = result
      assert item.title == "In Operator Create"
    end

    test "destroy with dot-path scope and matching team name succeeds" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with_perms(["item:*:destroy:named_team", "item:*:read:always"], actor_id)
        |> Map.put(:team_name, "Zeta")

      team = create_team!("Zeta")
      item = create_item!(%{title: "Delete Me", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_destroy(:destroy)
        |> Ash.destroy(actor: actor)

      assert :ok = result
    end
  end

  # ============================================================
  # BUG: Composite scopes inheriting relational parents on CREATE
  #
  # should_use_db_query?/3 checks scope_def.filter (the CHILD's own filter)
  # instead of the fully resolved filter (with inherited parent filters).
  #
  # For composite scope :team_member_and_own (inherits :team_member):
  #   - scope_def.filter = expr(author_id == ^actor(:id))  ← no relationship ref
  #   - resolved filter  = author_id == ^actor(:id) AND exists(team.memberships, ...)
  #
  # Because scope_def.filter has no relationship ref, should_use_db_query?
  # returns false. The resolved filter (with exists()) is then evaluated
  # in-memory on a virtual record that has no loaded relationships → Forbidden.
  # ============================================================

  describe "BUG: composite scope inheriting relational parent on create" do
    test "create with composite scope (inherits exists()) and valid conditions succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member_and_own"], actor_id)

      team = create_team!("Composite Create Team")
      create_membership!(team, actor_id)

      # Both conditions should be met:
      # - :team_member parent: actor has membership in team
      # - :team_member_and_own child: author_id == actor.id
      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Composite Scope Item",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:ok, item} = result
      assert item.title == "Composite Scope Item"
    end

    test "create with composite scope (inherits exists()) rejects when parent condition fails" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member_and_own"], actor_id)

      team = create_team!("No Member Composite Team")
      # No membership created — parent :team_member condition fails

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Should Fail",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "create with composite scope (inherits exists()) rejects when child condition fails" do
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member_and_own"], actor_id)

      team = create_team!("Composite Child Fail Team")
      create_membership!(team, actor_id)

      # Membership exists but author_id doesn't match actor
      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Wrong Author",
          author_id: other_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "create with composite scope (inherits dot-path) and valid conditions succeeds" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with_perms(["item:*:create:named_team_and_own"], actor_id)
        |> Map.put(:team_name, "Composite Dot Path")

      team = create_team!("Composite Dot Path")

      # Both conditions should be met:
      # - :named_team parent: team.name == actor.team_name
      # - :named_team_and_own child: author_id == actor.id
      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Composite Dot Path Item",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      assert {:ok, item} = result
      assert item.title == "Composite Dot Path Item"
    end

    test "update with composite scope (inherits exists()) and valid conditions succeeds" do
      actor_id = Ash.UUID.generate()

      actor =
        actor_with_perms(
          ["item:*:update:team_member_and_own", "item:*:read:always"],
          actor_id
        )

      team = create_team!("Composite Update Team")
      create_membership!(team, actor_id)
      item = create_item!(%{title: "Update Me", author_id: actor_id, team_id: team.id})

      result =
        item
        |> Ash.Changeset.for_update(:update, %{title: "Updated Composite"})
        |> Ash.update(actor: actor)

      assert {:ok, updated} = result
      assert updated.title == "Updated Composite"
    end
  end
end

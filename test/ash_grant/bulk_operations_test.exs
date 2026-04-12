defmodule AshGrant.BulkOperationsTest do
  @moduledoc """
  Tests for bulk operations (bulk_create, bulk_update, bulk_destroy) with
  scope-based authorization, specifically the exists() scope crash fix.

  Issue #23: Ash.bulk_create/4 crashes when the resource has an exists()
  scope expression because check_create_scope tries to evaluate exists()
  on a virtual record (plain map) without resource metadata.
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

  # === bulk_create Tests ===

  describe "bulk_create" do
    test "with all scope creates all items" do
      actor = actor_with_perms(["item:*:create:always"])

      inputs = [
        %{title: "Item 1", author_id: actor.id},
        %{title: "Item 2", author_id: actor.id},
        %{title: "Item 3", author_id: actor.id}
      ]

      result =
        Ash.bulk_create(inputs, BulkItem, :create,
          actor: actor,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 3
    end

    test "with own scope and matching author_id succeeds" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:own"], actor_id)

      inputs = [
        %{title: "My Item 1", author_id: actor_id},
        %{title: "My Item 2", author_id: actor_id}
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

    test "with own scope and mismatched author_id via single create is forbidden" do
      # Single create properly enforces per-record scope checks
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:own"], actor_id)

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{title: "Other's Item", author_id: other_id})
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "with exists() scope (team_member) succeeds via DB query" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member"], actor_id)

      team = create_team!("Test Team")
      create_membership!(team, actor_id)

      inputs = [
        %{title: "Team Item 1", author_id: actor_id, team_id: team.id},
        %{title: "Team Item 2", author_id: actor_id, team_id: team.id}
      ]

      # DB query fallback: checks parent team membership via DB query
      result =
        Ash.bulk_create(inputs, BulkItem, :create,
          actor: actor,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 2
    end

    test "without any permission is forbidden" do
      actor = actor_with_perms([])

      inputs = [%{title: "No Permission Item"}]

      result =
        Ash.bulk_create(inputs, BulkItem, :create,
          actor: actor,
          return_errors?: true
        )

      assert result.status == :error
    end

    test "with deny rule is forbidden" do
      actor = actor_with_perms(["item:*:create:always", "!item:*:create:always"])

      inputs = [%{title: "Denied Item"}]

      result =
        Ash.bulk_create(inputs, BulkItem, :create,
          actor: actor,
          return_errors?: true
        )

      assert result.status == :error
    end

    test "with mixed scope (own + exists) evaluates both via DB query" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:own_in_team"], actor_id)

      team = create_team!("Mixed Scope Team")
      create_membership!(team, actor_id)

      # author_id matches actor AND exists() verified via DB query
      inputs = [
        %{title: "Mixed Item", author_id: actor_id, team_id: team.id}
      ]

      result =
        Ash.bulk_create(inputs, BulkItem, :create,
          actor: actor,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 1
    end

    test "with mixed scope (own + exists) rejects mismatched author_id via single create" do
      # Single create properly enforces per-record scope checks for mixed scopes
      actor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:own_in_team"], actor_id)

      team = create_team!("Mixed Scope Team 2")
      create_membership!(team, actor_id)

      # author_id does NOT match actor - should be forbidden
      # exists() is simplified to true, but author_id check still fails
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
  end

  # === Single create + exists() regression ===

  describe "single create with exists() scope" do
    test "with team_member scope succeeds via DB query" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:create:team_member"], actor_id)

      team = create_team!("Single Create Team")
      create_membership!(team, actor_id)

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{
          title: "Single Item",
          author_id: actor_id,
          team_id: team.id
        })
        |> Ash.create(actor: actor)

      # DB query fallback: checks parent team membership via DB query
      assert {:ok, item} = result
      assert item.title == "Single Item"
    end

    test "with exists-only scope and no permission is forbidden" do
      actor = actor_with_perms([])

      result =
        BulkItem
        |> Ash.Changeset.for_create(:create, %{title: "No Perm"})
        |> Ash.create(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  # === bulk_update Tests ===

  describe "bulk_update" do
    test "with all scope updates all items" do
      actor = actor_with_perms(["item:*:update:always"])

      _item1 = create_item!(%{title: "Update Me 1", author_id: actor.id})
      _item2 = create_item!(%{title: "Update Me 2", author_id: actor.id})

      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_update(:update, %{title: "Updated"},
          actor: actor,
          strategy: :stream,
          authorize_query?: false,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 2
      assert Enum.all?(result.records, &(&1.title == "Updated"))
    end

    test "with own scope updates own items" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:own", "item:*:read:always"], actor_id)

      _own_item = create_item!(%{title: "My Item", author_id: actor_id})

      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_update(:update, %{title: "My Updated Item"},
          actor: actor,
          strategy: :stream,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 1
      assert hd(result.records).title == "My Updated Item"
    end

    test "with deny rule rejects updates" do
      actor =
        actor_with_perms(["item:*:update:always", "!item:*:update:always", "item:*:read:always"])

      _item = create_item!(%{title: "Deny Update", author_id: actor.id})

      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_update(:update, %{title: "Should Not Work"},
          actor: actor,
          strategy: :stream,
          return_errors?: true
        )

      # Deny-wins: items are rejected (may be :error or :partial_success depending on strategy)
      assert result.status in [:error, :partial_success]
      assert result.error_count > 0
    end

    test "with exists() scope (team_member) succeeds via DB query" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:update:team_member", "item:*:read:always"], actor_id)

      team = create_team!("Update Team")
      create_membership!(team, actor_id)
      _item = create_item!(%{title: "Team Update Item", author_id: actor_id, team_id: team.id})

      # DB query fallback: checks record matches read scope via DB
      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_update(:update, %{title: "Updated Team Item"},
          actor: actor,
          strategy: :stream,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 1
      assert hd(result.records).title == "Updated Team Item"
    end
  end

  # === bulk_destroy Tests ===

  describe "bulk_destroy" do
    test "with all scope destroys all items" do
      actor = actor_with_perms(["item:*:destroy:always", "item:*:read:always"])

      _item1 = create_item!(%{title: "Delete Me 1", author_id: actor.id})
      _item2 = create_item!(%{title: "Delete Me 2", author_id: actor.id})

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
      assert length(result.records) == 2
    end

    test "with own scope destroys own items" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:destroy:own", "item:*:read:always"], actor_id)

      _own_item = create_item!(%{title: "My Delete Item", author_id: actor_id})

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

    test "with deny rule rejects destroys" do
      actor =
        actor_with_perms([
          "item:*:destroy:always",
          "!item:*:destroy:always",
          "item:*:read:always"
        ])

      _item = create_item!(%{title: "Deny Delete", author_id: actor.id})

      result =
        BulkItem
        |> Ash.Query.for_read(:read)
        |> Ash.bulk_destroy(:destroy, %{},
          actor: actor,
          strategy: :stream,
          authorize_query?: false,
          return_errors?: true
        )

      # Deny-wins: items are rejected (may be :error or :partial_success depending on strategy)
      assert result.status in [:error, :partial_success]
      assert result.error_count > 0
    end

    test "with exists() scope (team_member) succeeds via DB query" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:destroy:team_member", "item:*:read:always"], actor_id)

      team = create_team!("Destroy Team")
      create_membership!(team, actor_id)
      _item = create_item!(%{title: "Team Delete Item", author_id: actor_id, team_id: team.id})

      # DB query fallback: checks record matches read scope via DB
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
end

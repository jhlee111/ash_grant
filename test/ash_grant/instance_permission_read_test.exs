defmodule AshGrant.InstancePermissionReadTest do
  @moduledoc """
  TDD tests for instance permission read support.

  Instance permissions should work with read actions (filter_check),
  allowing users to read specific shared resources.

  Example use case: Google Docs-style sharing where specific documents
  are shared with specific users.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.SharedDoc

  describe "instance permission read with filter_check" do
    test "user can read a specific shared document" do
      # Create documents
      doc1 = create_shared_doc("Doc 1", "owner-1")
      doc2 = create_shared_doc("Doc 2", "owner-2")
      _doc3 = create_shared_doc("Doc 3", "owner-3")

      # Actor has instance permission to read doc1 and doc2
      actor = %{
        id: "reader-1",
        role: :guest,
        shared_doc_ids: [doc1.id, doc2.id]
      }

      # Should only see doc1 and doc2
      docs = SharedDoc |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      assert length(docs) == 2
      assert doc1.id in ids
      assert doc2.id in ids
    end

    test "user with no instance permissions is forbidden" do
      _doc1 = create_shared_doc("Doc 1", "owner-1")

      actor = %{id: "reader-1", role: :guest, shared_doc_ids: []}

      # When FilterCheck returns false (no permissions at all),
      # Ash raises Forbidden at strict_check stage
      assert_raise Ash.Error.Forbidden, fn ->
        SharedDoc |> Ash.read!(actor: actor)
      end
    end

    test "instance permission combined with RBAC permission" do
      doc1 = create_shared_doc("Doc 1", "owner-1")
      doc2 = create_shared_doc("Doc 2", "owner-1")
      doc3 = create_shared_doc("Doc 3", "owner-2")

      # Actor owns doc1 and doc2 (RBAC), and has instance permission for doc3
      actor = %{
        id: "owner-1",
        role: :user,
        shared_doc_ids: [doc3.id]
      }

      docs = SharedDoc |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      assert length(docs) == 3
      assert doc1.id in ids
      assert doc2.id in ids
      assert doc3.id in ids
    end

    test "deny instance permission blocks read" do
      doc1 = create_shared_doc("Doc 1", "owner-1")

      # Actor has instance permission but also deny - deny wins
      actor = %{
        id: "reader-1",
        role: :guest,
        shared_doc_ids: [doc1.id],
        denied_doc_ids: [doc1.id]
      }

      # When all instance permissions are denied, FilterCheck returns false
      # and Ash raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        SharedDoc |> Ash.read!(actor: actor)
      end
    end

    test "Ash.get! returns document when instance permission exists" do
      doc1 = create_shared_doc("Doc 1", "owner-1")

      actor = %{
        id: "reader-1",
        role: :guest,
        shared_doc_ids: [doc1.id]
      }

      result = Ash.get(SharedDoc, doc1.id, actor: actor)

      assert {:ok, doc} = result
      assert doc.id == doc1.id
    end

    test "Ash.get returns Forbidden when no instance permission" do
      doc1 = create_shared_doc("Doc 1", "owner-1")

      actor = %{
        id: "reader-1",
        role: :guest,
        shared_doc_ids: []
      }

      # When FilterCheck returns false, Ash.get returns Forbidden
      # (not NotFound, because the filter is rejected at strict_check stage)
      result = Ash.get(SharedDoc, doc1.id, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "Evaluator.get_matching_instance_ids/3" do
    test "returns instance IDs for matching permissions" do
      permissions = [
        "shareddoc:doc_abc:read:",
        "shareddoc:doc_xyz:read:",
        "shareddoc:doc_123:write:"
      ]

      ids = AshGrant.Evaluator.get_matching_instance_ids(permissions, "shareddoc", "read")

      assert length(ids) == 2
      assert "doc_abc" in ids
      assert "doc_xyz" in ids
    end

    test "returns empty list when no matching instance permissions" do
      permissions = [
        "shareddoc:*:read:all",
        "otherdoc:doc_abc:read:"
      ]

      ids = AshGrant.Evaluator.get_matching_instance_ids(permissions, "shareddoc", "read")

      assert ids == []
    end

    test "excludes denied instance permissions" do
      permissions = [
        "shareddoc:doc_abc:read:",
        "shareddoc:doc_xyz:read:",
        "!shareddoc:doc_xyz:read:"
      ]

      ids = AshGrant.Evaluator.get_matching_instance_ids(permissions, "shareddoc", "read")

      assert ids == ["doc_abc"]
    end

    test "handles wildcard action matching" do
      permissions = [
        "shareddoc:doc_abc:*:"
      ]

      ids = AshGrant.Evaluator.get_matching_instance_ids(permissions, "shareddoc", "read")

      assert ids == ["doc_abc"]
    end
  end

  # Helper functions

  defp create_shared_doc(title, owner_id) do
    SharedDoc
    |> Ash.Changeset.for_create(:create, %{title: title, owner_id: owner_id})
    |> Ash.create!(authorize?: false)
  end
end

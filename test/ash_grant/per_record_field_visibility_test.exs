defmodule AshGrant.PerRecordFieldVisibilityTest do
  @moduledoc """
  End-to-end tests for per-record field visibility (issue #117 phase ②, stage 3).

  A field can be visible on some records and `%Ash.ForbiddenField{}` on others in
  the same result set, decided by each grant's scope / instance id. This is the
  pattern the action-wide field model cannot express.

  Uses `AshGrant.Test.OwnedRecord`: field groups `:public [:title] ⊂ :sensitive
  [:secret]`, scopes `:always` and `:own` (`owner_id == ^actor(:id)`).
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.OwnedRecord

  defp create_record!(owner_id, attrs) do
    OwnedRecord
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :owner_id, owner_id), authorize?: false)
    |> Ash.create!()
  end

  defp read(actor), do: OwnedRecord |> Ash.read!(actor: actor)
  defp find(results, id), do: Enum.find(results, &(&1.id == id))
  defp forbidden?(value), do: match?(%Ash.ForbiddenField{}, value)

  setup do
    mine = create_record!("u1", %{title: "Mine", secret: "my-secret"})
    other = create_record!("u2", %{title: "Theirs", secret: "their-secret"})
    %{mine: mine, other: other}
  end

  describe "scope-conditioned field visibility (the demonstrator)" do
    test "public on all rows, sensitive only on own rows", %{mine: mine, other: other} do
      actor = %{
        id: "u1",
        permissions: [
          "ownedrecord:*:read:always:public",
          "ownedrecord:*:read:own:sensitive"
        ]
      }

      results = read(actor)
      mine_row = find(results, mine.id)
      other_row = find(results, other.id)

      # Both rows are readable (the :always:public grant gives broad row access).
      assert mine_row != nil
      assert other_row != nil

      # public field visible on BOTH
      assert mine_row.title == "Mine"
      assert other_row.title == "Theirs"

      # sensitive field visible on OWN row, forbidden on the other
      assert mine_row.secret == "my-secret"
      assert forbidden?(other_row.secret)
    end
  end

  describe "instance-conditioned field visibility" do
    test "sensitive visible only on the named instance", %{mine: mine, other: other} do
      actor = %{
        id: "anyone",
        permissions: [
          "ownedrecord:*:read:always:public",
          "ownedrecord:#{mine.id}:read::sensitive"
        ]
      }

      results = read(actor)

      assert find(results, mine.id).secret == "my-secret"
      assert forbidden?(find(results, other.id).secret)
    end
  end

  describe "ungrouped fields" do
    test "a public field in no field_group is visible to any actor with row access", %{
      mine: mine,
      other: other
    } do
      # owner_id is in no field_group — it must stay visible (covered by the
      # catch-all), not become %Ash.ForbiddenField{}.
      actor = %{id: "u1", permissions: ["ownedrecord:*:read:always:public"]}
      results = read(actor)

      refute forbidden?(find(results, mine.id).owner_id)
      assert find(results, mine.id).owner_id == "u1"
      assert find(results, other.id).owner_id == "u2"
    end
  end

  describe "backward-compat: trivial scope stays action-wide" do
    test "a trivial-scope sensitive grant shows the field on every row", %{
      mine: mine,
      other: other
    } do
      actor = %{id: "u1", permissions: ["ownedrecord:*:read:always:sensitive"]}
      results = read(actor)

      assert find(results, mine.id).secret == "my-secret"
      assert find(results, other.id).secret == "their-secret"
    end

    test "public-only grant forbids sensitive on every row", %{mine: mine, other: other} do
      actor = %{id: "u1", permissions: ["ownedrecord:*:read:always:public"]}
      results = read(actor)

      assert forbidden?(find(results, mine.id).secret)
      assert forbidden?(find(results, other.id).secret)
      assert find(results, mine.id).title == "Mine"
    end
  end
end

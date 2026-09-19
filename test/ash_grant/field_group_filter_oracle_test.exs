defmodule AshGrant.FieldGroupFilterOracleTest do
  @moduledoc """
  A field hidden by a generated field policy must not be readable through a filter.

  Ash replaces a forbidden field referenced in a filter with an expression that
  evaluates to `nil`, so `filter(secret == "x")` cannot be used as a yes/no oracle
  on a value the actor cannot see. Before Ash 3.33.4 that replacement covered
  attributes only: a calculation or aggregate was filtered against its real value
  (CVE-2026-86338, GHSA-7qr8-wrvq-566q).

  `default_field_policies` accepts calculations and aggregates in a `field_group`,
  so the policies AshGrant generates were exposed to it. These tests pin the fixed
  behaviour for all three field kinds, action-wide and per record.

  Uses `AshGrant.Test.ComputedFieldRecord`: field groups `:public [:title] ⊂
  :sensitive [:secret, :secret_calc, :note_count]`, scopes `:always` and `:own`.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.ComputedFieldNote
  alias AshGrant.Test.ComputedFieldRecord

  defp create_record!(owner_id, attrs, note_count) do
    record =
      ComputedFieldRecord
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :owner_id, owner_id), authorize?: false)
      |> Ash.create!()

    for _ <- 1..note_count//1 do
      ComputedFieldNote
      |> Ash.Changeset.for_create(:create, %{record_id: record.id})
      |> Ash.create!()
    end

    record
  end

  defp filtered_ids(actor, filter) do
    ComputedFieldRecord
    |> Ash.Query.filter_input(filter)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp forbidden?(value), do: match?(%Ash.ForbiddenField{}, value)

  setup do
    mine = create_record!("u1", %{title: "Mine", secret: "my-secret"}, 1)
    other = create_record!("u2", %{title: "Theirs", secret: "their-secret"}, 2)
    %{mine: mine, other: other}
  end

  describe "an actor granted the :sensitive group" do
    setup do
      %{actor: %{id: "u1", permissions: ["computedfieldrecord:*:read:always:sensitive"]}}
    end

    test "can filter on the attribute", %{actor: actor, other: other} do
      assert filtered_ids(actor, secret: "their-secret") == [other.id]
    end

    test "can filter on the calculation", %{actor: actor, other: other} do
      assert filtered_ids(actor, secret_calc: "their-secret") == [other.id]
    end

    test "can filter on the aggregate", %{actor: actor, other: other} do
      assert filtered_ids(actor, note_count: 2) == [other.id]
    end
  end

  describe "an actor granted only the :public group" do
    setup do
      %{actor: %{id: "u1", permissions: ["computedfieldrecord:*:read:always:public"]}}
    end

    test "reads every row, with the computed fields forbidden", %{actor: actor} do
      results =
        ComputedFieldRecord
        |> Ash.Query.load([:secret_calc, :note_count])
        |> Ash.read!(actor: actor)

      assert length(results) == 2

      for row <- results do
        assert forbidden?(row.secret)
        assert forbidden?(row.secret_calc)
        assert forbidden?(row.note_count)
      end
    end

    test "filtering on the attribute sees nil", %{actor: actor} do
      assert filtered_ids(actor, secret: "their-secret") == []
    end

    test "filtering on the calculation sees nil", %{actor: actor} do
      assert filtered_ids(actor, secret_calc: "their-secret") == []
    end

    test "filtering on the aggregate sees nil", %{actor: actor} do
      assert filtered_ids(actor, note_count: 2) == []
    end
  end

  # `AshGrant.FieldFilterCheck` makes visibility a per-row predicate, so the nil
  # replacement has to be per row too: the same filter matches on the rows where
  # the field is visible and sees nil on the rows where it is not.
  describe "an actor granted :sensitive on own rows only" do
    setup do
      %{
        actor: %{
          id: "u1",
          permissions: [
            "computedfieldrecord:*:read:always:public",
            "computedfieldrecord:*:read:own:sensitive"
          ]
        }
      }
    end

    test "filters own rows by the attribute, calculation and aggregate", %{
      actor: actor,
      mine: mine
    } do
      assert filtered_ids(actor, secret: "my-secret") == [mine.id]
      assert filtered_ids(actor, secret_calc: "my-secret") == [mine.id]
      assert filtered_ids(actor, note_count: 1) == [mine.id]
    end

    test "cannot probe another owner's rows through any of them", %{actor: actor} do
      assert filtered_ids(actor, secret: "their-secret") == []
      assert filtered_ids(actor, secret_calc: "their-secret") == []
      assert filtered_ids(actor, note_count: 2) == []
    end
  end
end

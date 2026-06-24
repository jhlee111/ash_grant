defmodule AshGrant.FieldFilterCheckTest do
  @moduledoc """
  Unit tests for `AshGrant.FieldFilterCheck.field_visibility_filter/5`
  (issue #117 phase ②, stage 2).

  Tests the per-row predicate the check builds for a required field group:
  `false` (forbid everywhere), `true` (visible everywhere), or an Ash expression
  (visible only on rows matching the grants' scope / instance ids).

  Uses `AshGrant.Test.OwnedRecord`: field groups `:public [:title] ⊂ :sensitive
  [:secret]`, scopes `:always` and `:own` (`owner_id == ^actor(:id)`).
  """
  use ExUnit.Case, async: true

  alias AshGrant.FieldFilterCheck
  alias AshGrant.Test.OwnedRecord

  defp vis(perms, group, action \\ "read", action_type \\ nil) do
    FieldFilterCheck.field_visibility_filter(perms, OwnedRecord, action, group, action_type)
  end

  describe "boolean cases" do
    test "no grant for the group => false (forbidden on every row)" do
      assert vis([], :sensitive) == false
      assert vis(["ownedrecord:*:read:always:public"], :sensitive) == false
    end

    test "group-less grant with a trivial scope => true (visible on every row)" do
      assert vis(["ownedrecord:*:read:always"], :sensitive) == true
    end

    test "direct grant with a trivial scope => true" do
      assert vis(["ownedrecord:*:read:always:sensitive"], :sensitive) == true
    end

    test "inherited grant with a trivial scope => true (sensitive grants public)" do
      assert vis(["ownedrecord:*:read:always:sensitive"], :public) == true
    end
  end

  describe "scoped (per-row) cases" do
    test "a non-trivial scope yields an expression, not a boolean" do
      result = vis(["ownedrecord:*:read:own:sensitive"], :sensitive)
      refute result === true
      refute result === false
      assert inspect(result) =~ "owner_id"
    end

    test "a group-less grant with a non-trivial scope is scoped (D3), not all-rows" do
      result = vis(["ownedrecord:*:read:own"], :sensitive)
      refute result === true
      refute result === false
      assert inspect(result) =~ "owner_id"
    end

    test "an instance grant yields an id predicate" do
      result = vis(["ownedrecord:rec1:read::sensitive"], :sensitive)
      refute result === true
      refute result === false
      assert inspect(result) =~ "rec1"
    end
  end

  describe "the demonstrator: public on all rows + sensitive on own rows" do
    @shape5 [
      "ownedrecord:*:read:always:public",
      "ownedrecord:*:read:own:sensitive"
    ]

    test ":public is visible on every row (true)" do
      assert vis(@shape5, :public) == true
    end

    test ":sensitive is visible only on own rows (scoped expression)" do
      result = vis(@shape5, :sensitive)
      refute result === true
      refute result === false
      assert inspect(result) =~ "owner_id"
    end
  end
end

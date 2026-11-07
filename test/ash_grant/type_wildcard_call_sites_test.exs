defmodule AshGrant.TypeWildcardCallSitesTest do
  @moduledoc """
  A type wildcard (`@read`, `@update`, ...) only matches when the caller
  supplies the action type. These call sites evaluated grants without one, so a
  grant written with a type wildcard was skipped:

  - `AshGrant.Preparations.ApplyMasking` skipped the grant's field group, so a
    field the group masks came back unmasked, while `AshGrant.FieldFilterCheck`
    (which passes the type) still showed it.
  - `AshGrant.Calculation.CanPerform` skipped the grant's scope, so
    `can_update?` was false on records the update itself was allowed on.
  - `AshGrant.PolicyTest.Assertions.resolve_visible_fields/3` (behind
    `assert_fields_visible`/`assert_fields_hidden`) reported no access.

  Each test compares the type wildcard with the exact action name, which these
  call sites already handled.

  `async: false`: `MaskedRecord` is a shared ETS table, and on Ash below 3.37.1
  concurrent first access to one can fail with `:table_not_found`
  (ash-project/ash#3083).
  """
  use AshGrant.DataCase, async: false

  import AshGrant.Test.Generator

  alias AshGrant.PolicyTest.Assertions
  alias AshGrant.Test.{ChildComment, MaskedRecord, Post}

  defp masked_record! do
    MaskedRecord
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Ann", department: "Ops", phone: "010-1234", address: "Main St"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp read_one(resource, actor, id) do
    resource |> Ash.read!(actor: actor) |> Enum.find(&(&1.id == id))
  end

  describe "masking" do
    for action <- ["read", "@read"] do
      test "a #{action} grant with a masking field group masks the field" do
        record = masked_record!()
        actor = %{permissions: ["maskedrecord:*:#{unquote(action)}:always:sensitive"]}

        result = read_one(MaskedRecord, actor, record.id)

        assert result.name == "Ann"
        assert result.phone == "********"
        assert result.address == "*******"
      end
    end

    test "a @read grant with an unmasked group still beats a masking one (allow-wins)" do
      record = masked_record!()

      actor = %{
        permissions: [
          "maskedrecord:*:read:always:sensitive",
          "maskedrecord:*:@read:always:confidential"
        ]
      }

      result = read_one(MaskedRecord, actor, record.id)

      assert result.phone == "010-1234"
    end
  end

  describe "CanPerform" do
    for action <- ["update", "@update"] do
      test "an own-scoped #{action} grant makes can_update? true on the actor's posts only" do
        me = Ash.UUID.generate()
        mine = generate(post(author_id: me))
        other = generate(post(author_id: Ash.UUID.generate()))

        actor = %{
          id: me,
          permissions: ["post:*:read:always", "post:*:#{unquote(action)}:own"]
        }

        loaded =
          Post
          |> Ash.read!(actor: actor, load: [:can_update?])
          |> Map.new(&{&1.id, &1.can_update?})

        assert loaded[mine.id] == true
        assert loaded[other.id] == false

        # The update itself agrees with the calculation.
        assert {:ok, _} =
                 mine
                 |> Ash.Changeset.for_update(:update, %{title: "x"}, actor: actor)
                 |> Ash.update()
      end

      test "a parent instance #{action} grant makes can_update? true on that post's comments only" do
        post = generate(post(author_id: Ash.UUID.generate()))
        other_post = generate(post(author_id: Ash.UUID.generate()))
        comment = comment!(post)
        other_comment = comment!(other_post)

        actor = %{
          id: Ash.UUID.generate(),
          permissions: ["child_comment:*:read:always", "post:#{post.id}:#{unquote(action)}:"]
        }

        loaded =
          ChildComment
          |> Ash.read!(actor: actor, load: [:can_update?])
          |> Map.new(&{&1.id, &1.can_update?})

        assert loaded[comment.id] == true
        assert loaded[other_comment.id] == false

        # The update itself agrees with the calculation.
        assert {:ok, _} =
                 comment
                 |> Ash.Changeset.for_update(:update, %{body: "x"}, actor: actor)
                 |> Ash.update()
      end
    end
  end

  defp comment!(post) do
    ChildComment
    |> Ash.Changeset.for_create(
      :create,
      %{body: "b", post_id: post.id, user_id: Ash.UUID.generate()},
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "resolve_visible_fields/3" do
    for action <- ["read", "@read"] do
      test "a #{action} grant with a field group reports that group's fields" do
        actor = %{permissions: ["maskedrecord:*:#{unquote(action)}:always:public"]}

        assert Enum.sort(Assertions.resolve_visible_fields(MaskedRecord, actor, :read)) ==
                 [:department, :name]
      end

      test "a #{action} grant with no field group reports all fields" do
        actor = %{permissions: ["maskedrecord:*:#{unquote(action)}:always"]}

        assert Assertions.resolve_visible_fields(MaskedRecord, actor, :read) == :all_fields
      end
    end
  end
end

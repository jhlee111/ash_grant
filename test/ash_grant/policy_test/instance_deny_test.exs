defmodule AshGrant.PolicyTest.InstanceDenyTest do
  @moduledoc """
  The policy test checker applies instance denies (`!post:<id>:read:`) as the
  runtime does since #188: a deny removes its record from every grant that would
  otherwise admit it (RBAC, instance and `scope_through`), with ids cast to the
  instance key's type.

  Every case asks the runtime first and the checker second, on the same record
  and the same actor, and expects the same answer.
  """
  use AshGrant.DataCase, async: false

  import AshGrant.Test.Generator

  alias AshGrant.PolicyTest.Checker
  alias AshGrant.Test.{ChildComment, Post}

  defp actor(permissions), do: %{id: Ash.UUID.generate(), permissions: permissions}

  defp record_map(record) do
    Map.take(record, Ash.Resource.Info.attribute_names(record.__struct__) |> Enum.to_list())
  end

  defp runtime(:read, record, actor) do
    case Ash.read(record.__struct__, actor: actor) do
      {:ok, rows} -> if Enum.any?(rows, &(&1.id == record.id)), do: :allow, else: :deny
      {:error, %Ash.Error.Forbidden{}} -> :deny
    end
  end

  defp runtime(:update, record, actor) do
    attrs = if record.__struct__ == ChildComment, do: %{body: "x"}, else: %{title: "x"}

    case record |> Ash.Changeset.for_update(:update, attrs, actor: actor) |> Ash.update() do
      {:ok, _} -> :allow
      {:error, %Ash.Error.Forbidden{}} -> :deny
    end
  end

  defp checker(action, record, actor) do
    record.__struct__
    |> Checker.check(actor, action, record_map(record))
    |> elem(0)
  end

  defp assert_agree(action, record, actor, expected) do
    assert runtime(action, record, actor) == expected,
           "runtime #{action} on #{record.id}: expected #{expected}"

    assert checker(action, record, actor) == expected,
           "checker #{action} on #{record.id}: expected #{expected}, runtime says #{expected}"
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

  describe "an instance deny under an RBAC grant" do
    setup do
      %{denied: generate(post()), other: generate(post())}
    end

    test "removes its record from reads and writes, and only that record", %{
      denied: denied,
      other: other
    } do
      a =
        actor([
          "post:*:read:always",
          "post:*:update:always",
          "!post:#{denied.id}:read:",
          "!post:#{denied.id}:update:"
        ])

      for action <- [:read, :update] do
        assert_agree(action, denied, a, :deny)
        assert_agree(action, other, a, :allow)
      end
    end

    test "matches an id written in another case, as the cast UUID", %{denied: denied} do
      a = actor(["post:*:update:always", "!post:#{String.upcase(denied.id)}:update:"])
      assert_agree(:update, denied, a, :deny)
    end

    test "ignores an id the instance key cannot cast", %{denied: denied} do
      a = actor(["post:*:read:always", "!post:not-a-uuid:read:"])
      assert_agree(:read, denied, a, :allow)
    end

    test "applies only to the action it names", %{denied: denied} do
      a = actor(["post:*:read:always", "post:*:update:always", "!post:#{denied.id}:update:"])
      assert_agree(:read, denied, a, :allow)
      assert_agree(:update, denied, a, :deny)
    end

    test "matches by action type", %{denied: denied} do
      a = actor(["post:*:read:always", "!post:#{denied.id}:@read:"])
      assert_agree(:read, denied, a, :deny)
    end
  end

  test "an instance deny beats an instance grant for the same record" do
    post = generate(post())
    assert_agree(:read, post, actor(["post:#{post.id}:read:", "!post:#{post.id}:read:"]), :deny)
  end

  describe "an instance deny on a scope_through child" do
    setup do
      parent = generate(post())
      %{parent: parent, denied: comment!(parent), other: comment!(parent)}
    end

    test "beats an RBAC grant on the child", %{denied: denied, other: other} do
      a = actor(["child_comment:*:read:always", "!child_comment:#{denied.id}:read:"])
      assert_agree(:read, denied, a, :deny)
      assert_agree(:read, other, a, :allow)
    end

    test "beats a parent instance grant", %{parent: parent, denied: denied, other: other} do
      a = actor(["post:#{parent.id}:read:", "!child_comment:#{denied.id}:read:"])
      assert_agree(:read, denied, a, :deny)
      assert_agree(:read, other, a, :allow)
    end
  end

  test "a record without its instance key is undecided while an instance deny is in play" do
    post = generate(post())
    a = actor(["post:*:read:always", "!post:#{post.id}:read:"])

    assert {:indeterminate, %{undecided: [reason]}} =
             Checker.check(Post, a, :read, Map.delete(record_map(post), :id))

    assert reason =~ "instance deny"
  end

  test "a YAML record holding its id as an atom is matched" do
    post = generate(post())
    a = actor(["post:*:read:always", "!post:#{post.id}:read:"])
    record = %{record_map(post) | id: String.to_atom(post.id)}
    assert {:deny, %{reason: :denied_by_instance_rule}} = Checker.check(Post, a, :read, record)
  end

  test "an instance deny does not touch a create" do
    a = actor(["post:*:create:always", "!post:#{Ash.UUID.generate()}:create:"])
    assert {:allow, _} = Checker.check(Post, a, :create, %{title: "new"})
  end
end

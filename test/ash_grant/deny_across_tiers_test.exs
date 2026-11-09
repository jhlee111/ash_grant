defmodule AshGrant.DenyAcrossTiersTest do
  @moduledoc """
  Deny rules override allows across the RBAC tier (`resource:*:action:scope`) and
  the instance tier (`resource:<id>:action:`), on reads, writes, `CanPerform` and
  `Introspect.can?/4`.
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Introspect
  alias AshGrant.Test.{ChildComment, Post}

  defp actor(permissions), do: %{id: Ash.UUID.generate(), permissions: permissions}

  # A filter that resolves to `false` makes Ash raise Forbidden instead of
  # returning `[]`; both mean the actor sees nothing.
  defp read_ids(resource, actor) do
    case Ash.read(resource, actor: actor) do
      {:ok, records} -> records |> Enum.map(& &1.id) |> Enum.sort()
      {:error, %Ash.Error.Forbidden{}} -> []
    end
  end

  defp create_child_comment!(post_id) do
    ChildComment
    |> Ash.Changeset.for_create(:create, %{
      body: "comment",
      post_id: post_id,
      user_id: Ash.UUID.generate()
    })
    |> Ash.create!(authorize?: false)
  end

  defp can_update_by_id(actor) do
    Post
    |> Ash.Query.load(:can_update?)
    |> Ash.read!(actor: actor)
    |> Map.new(&{&1.id, &1.can_update?})
  end

  describe "RBAC deny + instance allow" do
    test "read returns no records" do
      post = generate(post())

      actor = actor(["!post:*:read:always", "post:#{post.id}:read:"])

      assert read_ids(Post, actor) == []
    end

    test "Introspect.can? denies the action" do
      post = generate(post())

      actor = actor(["!post:*:read:always", "post:#{post.id}:read:"])

      assert {:deny, %{reason: :denied_by_rule}} = Introspect.can?(Post, :read, actor)
    end

    test "CanPerform is false for the instance-granted record" do
      post = generate(post())

      actor =
        actor(["post:*:read:always", "!post:*:update:always", "post:#{post.id}:update:"])

      assert can_update_by_id(actor)[post.id] == false
    end

    test "scope_through parent grant does not reach children on read" do
      post = generate(post())
      _comment = create_child_comment!(post.id)

      actor = actor(["!child_comment:*:read:always", "post:#{post.id}:read:"])

      assert read_ids(ChildComment, actor) == []
    end
  end

  describe "RBAC allow + instance deny" do
    test "read excludes the denied record" do
      denied = generate(post())
      visible = generate(post())

      actor = actor(["post:*:read:always", "!post:#{denied.id}:read:"])

      ids = read_ids(Post, actor)
      refute denied.id in ids
      assert visible.id in ids
    end

    test "read with a non-universal scope excludes the denied record" do
      author_id = Ash.UUID.generate()
      denied = generate(post(author_id: author_id))
      visible = generate(post(author_id: author_id))

      actor = %{id: author_id, permissions: ["post:*:read:own", "!post:#{denied.id}:read:"]}

      assert read_ids(Post, actor) == Enum.sort([visible.id])
    end

    test "update of the denied record is forbidden" do
      denied = generate(post())

      actor = actor(["post:*:read:always", "post:*:update:always", "!post:#{denied.id}:update:"])

      assert {:error, %Ash.Error.Forbidden{}} =
               denied
               |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
               |> Ash.update()
    end

    test "update of another record still succeeds" do
      denied = generate(post())
      other = generate(post())

      actor = actor(["post:*:read:always", "post:*:update:always", "!post:#{denied.id}:update:"])

      assert {:ok, _} =
               other
               |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
               |> Ash.update()
    end

    test "destroy of the denied record is forbidden" do
      denied = generate(post())

      actor =
        actor(["post:*:read:always", "post:*:destroy:always", "!post:#{denied.id}:destroy:"])

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(denied, actor: actor)
    end

    test "CanPerform is false only for the denied record" do
      denied = generate(post())
      other = generate(post())

      actor = actor(["post:*:read:always", "post:*:update:always", "!post:#{denied.id}:update:"])

      can_update = can_update_by_id(actor)
      assert can_update[denied.id] == false
      assert can_update[other.id] == true
    end

    test "Introspect.can? allows the action and reports the denied instances" do
      denied = generate(post())

      actor = actor(["post:*:read:always", "!post:#{denied.id}:read:"])

      assert {:allow, %{denied_instance_ids: [denied_id]}} = Introspect.can?(Post, :read, actor)
      assert denied_id == denied.id
    end

    test "child records under a denied parent instance stay readable through RBAC" do
      post = generate(post())
      comment = create_child_comment!(post.id)

      actor = actor(["child_comment:*:read:always", "!post:#{post.id}:read:"])

      assert comment.id in read_ids(ChildComment, actor)
    end
  end

  describe "instance deny id spelling" do
    test "an uppercase UUID denies the update, as it hides the record on read" do
      denied = generate(post())
      upper_id = String.upcase(denied.id)

      actor = actor(["post:*:read:always", "post:*:update:always", "!post:#{upper_id}:update:"])

      assert {:error, %Ash.Error.Forbidden{}} =
               denied
               |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
               |> Ash.update()

      refute denied.id in read_ids(Post, actor(["post:*:read:always", "!post:#{upper_id}:read:"]))
    end

    test "an uppercase UUID makes CanPerform false for the denied record" do
      denied = generate(post())

      actor =
        actor([
          "post:*:read:always",
          "post:*:update:always",
          "!post:#{String.upcase(denied.id)}:update:"
        ])

      assert can_update_by_id(actor)[denied.id] == false
    end

    test "an id that does not cast to the instance key type denies nothing" do
      post = generate(post())

      actor = actor(["post:*:read:always", "post:*:update:always", "!post:not-a-uuid:read:"])

      assert post.id in read_ids(Post, actor)

      assert {:ok, _} =
               post
               |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
               |> Ash.update()
    end
  end

  describe "instance deny with a type wildcard" do
    test "!post:<id>:@read: hides the record" do
      denied = generate(post())
      visible = generate(post())

      ids = read_ids(Post, actor(["post:*:read:always", "!post:#{denied.id}:@read:"]))

      refute denied.id in ids
      assert visible.id in ids
    end

    test "!post:<id>:@update: forbids the update" do
      denied = generate(post())

      actor =
        actor(["post:*:read:always", "post:*:update:always", "!post:#{denied.id}:@update:"])

      assert {:error, %Ash.Error.Forbidden{}} =
               denied
               |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
               |> Ash.update()
    end

    test "is not reported as :dead_instance_type_wildcard" do
      assert AshGrant.Permission.diagnostics("!post:post_abc:@read:") == []
    end
  end

  describe "positive cases" do
    test "an instance allow without any deny returns the record" do
      post = generate(post())
      _other = generate(post())

      actor = actor(["post:#{post.id}:read:"])

      assert read_ids(Post, actor) == [post.id]
    end

    test "an RBAC allow returns every record when nothing is instance-denied" do
      a = generate(post())
      b = generate(post())

      ids = read_ids(Post, actor(["post:*:read:always"]))

      assert a.id in ids
      assert b.id in ids
    end
  end

  describe "diagnostics" do
    test "a deny carrying a scope reports :scoped_deny" do
      assert [%{code: :scoped_deny, message: message}] =
               AshGrant.Permission.diagnostics("!post:*:update:own")

      assert message =~ "ignored"
    end

    test "a deny with a universal scope reports nothing" do
      assert AshGrant.Permission.diagnostics("!post:*:update:always") == []
    end

    test "an allow carrying a scope reports nothing" do
      assert AshGrant.Permission.diagnostics("post:*:update:own") == []
    end
  end
end

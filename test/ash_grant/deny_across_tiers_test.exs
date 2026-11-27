defmodule AshGrant.DenyAcrossTiersTest do
  @moduledoc """
  Deny rules override allows across the RBAC tier (`resource:*:action:scope`) and
  the instance tier (`resource:<id>:action:`), on reads, writes, `CanPerform` and
  `Introspect.can?/4`.
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Introspect
  alias AshGrant.PolicyTest.Checker
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

  describe "parent instance deny id spelling (scope_through)" do
    # A parent instance deny cancels the parent's instance grants, so the children
    # they reach through scope_through go with them. Ids that differ only in case
    # name the same UUID, as they do on the parent's own read and write.
    setup do
      post = generate(post())
      comment = create_child_comment!(post.id)

      %{
        comment: comment,
        spellings: [
          {String.downcase(post.id), String.upcase(post.id)},
          {String.upcase(post.id), String.downcase(post.id)}
        ]
      }
    end

    test "hides the children on read", %{spellings: spellings} do
      for {allow, deny} <- spellings do
        actor = actor(["post:#{allow}:read:", "!post:#{deny}:read:"])

        assert read_ids(ChildComment, actor) == [], "allow #{allow}, deny #{deny}"
      end
    end

    test "forbids updating the children", %{comment: comment, spellings: spellings} do
      for {allow, deny} <- spellings do
        actor = actor(["post:#{allow}:update:", "!post:#{deny}:update:"])

        assert {:error, %Ash.Error.Forbidden{}} =
                 comment
                 |> Ash.Changeset.for_update(:update, %{body: "changed"}, actor: actor)
                 |> Ash.update(),
               "allow #{allow}, deny #{deny}"
      end
    end

    test "makes can_update? false on the children", %{comment: comment, spellings: spellings} do
      for {allow, deny} <- spellings do
        actor =
          actor(["child_comment:*:read:always", "post:#{allow}:update:", "!post:#{deny}:update:"])

        loaded =
          ChildComment
          |> Ash.Query.load(:can_update?)
          |> Ash.read!(actor: actor)
          |> Enum.find(&(&1.id == comment.id))

        assert loaded.can_update? == false, "allow #{allow}, deny #{deny}"
      end
    end

    test "Introspect.can?/4 and explain/4 deny the child action", %{spellings: spellings} do
      for {allow, deny} <- spellings do
        actor = actor(["post:#{allow}:read:", "!post:#{deny}:read:"])

        assert {:deny, _} = Introspect.can?(ChildComment, :read, actor),
               "allow #{allow}, deny #{deny}"

        explanation = AshGrant.explain(ChildComment, :read, actor)
        assert explanation.decision == :deny, "allow #{allow}, deny #{deny}"

        allow_line =
          Enum.find(explanation.evaluated_permissions, &(&1.permission == "post:#{allow}:read:"))

        refute allow_line.matched, "allow #{allow}, deny #{deny}"
        assert allow_line.reason =~ "Cancelled by an instance deny"
      end
    end

    test "the policy test checker denies the child", %{comment: comment, spellings: spellings} do
      for {allow, deny} <- spellings do
        actor = actor(["post:#{allow}:read:", "!post:#{deny}:read:"])

        assert {:deny, _} = Checker.check(ChildComment, actor, :read, comment),
               "allow #{allow}, deny #{deny}"
      end
    end
  end

  describe "parent instance grant id spelling (scope_through)" do
    test "an uppercase UUID lets the children be updated, as it lets them be read" do
      post = generate(post())
      comment = create_child_comment!(post.id)
      upper_id = String.upcase(post.id)

      assert comment.id in read_ids(ChildComment, actor(["post:#{upper_id}:read:"]))

      assert {:ok, _} =
               comment
               |> Ash.Changeset.for_update(:update, %{body: "changed"},
                 actor: actor(["post:#{upper_id}:update:"])
               )
               |> Ash.update()
    end

    test "an uppercase UUID admits the child in the policy test checker" do
      post = generate(post())
      comment = create_child_comment!(post.id)

      actor = actor(["post:#{String.upcase(post.id)}:read:"])

      assert {:allow, _} = Checker.check(ChildComment, actor, :read, comment)
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

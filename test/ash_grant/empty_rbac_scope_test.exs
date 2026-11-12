defmodule AshGrant.EmptyRbacScopeTest do
  @moduledoc """
  An RBAC allow grant with no scope authorizes nothing (issue #215).

  `post:*:update:` (and the legacy 2-part `post:update`, which parses to the
  same thing) used to authorize every update while `post:*:read:` read nothing:
  `AshGrant.Check` treated an empty scope as "no conditions" and every other
  path treated it as "no records". The write check now fails closed like the
  rest, and every path agrees.

  Instance grants keep their meaning: there an empty scope is the named record,
  without conditions.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.PolicyTest.Checker
  alias AshGrant.Test.Post

  defp actor(perms), do: %{id: Ash.UUID.generate(), permissions: perms}

  defp create_post!(author_id \\ Ash.UUID.generate()) do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "t", author_id: author_id}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp update_post(post, actor) do
    post
    |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
    |> Ash.update()
  end

  describe "writes" do
    test "an RBAC update grant with an empty scope is forbidden" do
      post = create_post!()

      assert {:error, %Ash.Error.Forbidden{}} = update_post(post, actor(["post:*:update:"]))
    end

    test "the legacy 2-part spelling is forbidden too" do
      post = create_post!()

      assert {:error, %Ash.Error.Forbidden{}} = update_post(post, actor(["post:update"]))
    end

    test "an empty-scope grant on every action authorizes no write" do
      post = create_post!()
      actor = actor(["post:*:*:"])

      assert {:error, %Ash.Error.Forbidden{}} = update_post(post, actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               post |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor) |> Ash.destroy()

      assert {:error, %Ash.Error.Forbidden{}} =
               Post
               |> Ash.Changeset.for_create(:create, %{title: "new"}, actor: actor)
               |> Ash.create()
    end

    test "a named scope still authorizes (control)" do
      post = create_post!()

      assert {:ok, %{title: "changed"}} = update_post(post, actor(["post:*:update:always"]))
    end

    test "an empty-scope grant does not widen a scoped one" do
      # It used to collapse the union to "every record".
      actor = actor(["post:*:update:own", "post:*:update:"])
      own = create_post!(actor.id)
      other = create_post!()

      assert {:ok, _} = update_post(own, actor)
      assert {:error, %Ash.Error.Forbidden{}} = update_post(other, actor)
    end
  end

  describe "every path agrees with the runtime" do
    setup do
      %{post: create_post!(), actor: actor(["post:*:read:", "post:*:update:"])}
    end

    test "the runtime reads nothing and writes nothing", %{post: post, actor: actor} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Post, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = update_post(post, actor)
    end

    test "can_update? is false", %{post: post, actor: actor} do
      assert %{can_update?: false} = Ash.load!(post, :can_update?, actor: actor)
    end

    test "Introspect.can?/4 denies", %{actor: actor} do
      assert {:deny, _} = AshGrant.Introspect.can?(Post, :update, actor)
      assert {:deny, _} = AshGrant.Introspect.can?(Post, :read, actor)
    end

    test "explain/4 denies", %{actor: actor} do
      assert AshGrant.explain(Post, :update, actor).decision == :deny
      assert AshGrant.explain(Post, :read, actor).decision == :deny
    end

    test "explain/4's scope filter ignores an empty-scope grant" do
      actor = actor(["post:*:update:own", "post:*:update:"])

      scoped =
        AshGrant.explain(Post, :update, actor(["post:*:update:own"]) |> Map.put(:id, actor.id))

      explained = AshGrant.explain(Post, :update, actor)

      assert explained.decision == :allow
      refute explained.scope_filter == true
      assert explained.scope_filter_string == scoped.scope_filter_string
    end

    test "PolicyTest.Checker denies", %{post: post, actor: actor} do
      assert {:deny, _} = Checker.check(Post, actor, :update, post)
      assert {:deny, _} = Checker.check(Post, actor, :read, post)
    end
  end

  describe "instance grants are unaffected" do
    test "an empty-scope instance read grant reads its record" do
      post = create_post!()
      _other = create_post!()
      actor = actor(["post:#{post.id}:read:"])

      assert [%{id: id}] = Ash.read!(Post, actor: actor)
      assert id == post.id
    end

    test "an empty-scope instance update grant does not reach the empty-RBAC-scope rule" do
      # Instance grants never enter `Evaluator.get_write_scopes/4`, so this change
      # cannot affect them. On main an instance grant does not authorize a write
      # whatever its scope; PR #195 changes that, and its own tests cover it.
      post = create_post!()
      actor = actor(["post:#{post.id}:update:"])

      assert AshGrant.Evaluator.get_write_scopes(actor.permissions, "post", "update", :update) ==
               {:scopes, []}

      assert AshGrant.Permission.diagnostics("post:#{post.id}:update:") == []
    end
  end
end

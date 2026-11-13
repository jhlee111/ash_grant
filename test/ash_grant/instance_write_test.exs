defmodule AshGrant.InstanceWriteTest do
  @moduledoc """
  Instance permissions (`resource:<instance_id>:action:scope`) authorize writes
  on the record they name.

  `AshGrant.Check` used to decide writes from RBAC grants alone, so an instance
  grant such as `post:<id>:update:` was Forbidden at runtime while `CanPerform`,
  `AshGrant.Introspect` and the policy-test checker all reported it as allowed.
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Test.{ChildComment, Post}

  require Ash.Query

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshGrant.InstanceWriteTest.Note)
    end
  end

  defmodule Note do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.InstanceWriteTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn
        %{permissions: perms}, _ -> perms
        _, _ -> []
      end)

      resource_name("note")
      default_policies(true)
      scope(:always, true)
      can_perform_actions([:update])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: [:title], update: [:title]])
    end
  end

  defp actor(permissions), do: %{id: Ash.UUID.generate(), permissions: permissions}

  defp update_as(record, actor, params \\ %{title: "changed"}) do
    record
    |> Ash.Changeset.for_update(:update, params, actor: actor)
    |> Ash.update()
  end

  defp can_update?(resource, record, actor) do
    resource
    |> Ash.Query.filter(id == ^record.id)
    |> Ash.Query.load(:can_update?)
    |> Ash.read_one!(actor: actor, authorize?: false)
    |> Map.fetch!(:can_update?)
  end

  describe "an instance grant on the record" do
    test "`update` authorizes the update" do
      post = generate(post())
      assert {:ok, _} = update_as(post, actor(["post:#{post.id}:update:"]))
    end

    test "`*` authorizes update and destroy" do
      post = generate(post())
      actor = actor(["post:#{post.id}:*:"])

      assert {:ok, post} = update_as(post, actor)
      assert :ok = Ash.destroy(post, actor: actor)
    end

    test "`destroy` authorizes the destroy but not an update" do
      post = generate(post())
      actor = actor(["post:#{post.id}:destroy:"])

      assert {:error, %Ash.Error.Forbidden{}} = update_as(post, actor)
      assert :ok = Ash.destroy(post, actor: actor)
    end

    test "authorizes other actions it names, by action name" do
      post = generate(post())
      actor = actor(["post:#{post.id}:publish:"])

      assert {:ok, %{status: :published}} =
               post |> Ash.Changeset.for_update(:publish, %{}, actor: actor) |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = update_as(post, actor)
    end

    test "an uppercase UUID still names the record" do
      post = generate(post())
      assert {:ok, _} = update_as(post, actor(["post:#{String.upcase(post.id)}:update:"]))
    end

    test "works on an Ets resource" do
      note = Ash.create!(Note, %{title: "t"}, authorize?: false)
      actor = actor(["note:#{note.id}:update:"])

      assert {:ok, _} = update_as(note, actor)
      assert can_update?(Note, note, actor)
    end
  end

  describe "an instance grant never reaches past its record" do
    test "another record stays forbidden" do
      post = generate(post())
      other = generate(post())

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(other, actor(["post:#{post.id}:update:"]))
    end

    test "another resource's instance grant does not apply" do
      post = generate(post())

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(post, actor(["comment:#{post.id}:update:"]))
    end

    test "a create is not authorized by an instance grant" do
      id = Ash.UUID.generate()

      assert {:error, %Ash.Error.Forbidden{}} =
               Post
               |> Ash.Changeset.for_create(:create, %{title: "t", author_id: id},
                 actor: actor(["post:#{id}:create:", "post:#{id}:*:"])
               )
               |> Ash.create()
    end

    test "a type wildcard on an instance permission matches by action type" do
      post = generate(post())
      actor = actor(["post:#{post.id}:@update:"])

      assert {:ok, %{status: :published}} =
               post |> Ash.Changeset.for_update(:publish, %{}, actor: actor) |> Ash.update()

      assert {:ok, post} = update_as(post, actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(post, actor: actor)
    end
  end

  describe "deny wins" do
    test "an RBAC deny overrides an instance allow" do
      post = generate(post())

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(post, actor(["!post:*:update:always", "post:#{post.id}:update:"]))
    end

    test "an instance deny on the record overrides its instance allow" do
      post = generate(post())

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(post, actor(["post:#{post.id}:*:", "!post:#{post.id}:update:"]))
    end

    test "an instance deny with a type wildcard cancels the instance allow" do
      post = generate(post())

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(post, actor(["post:#{post.id}:update:", "!post:#{post.id}:@update:"]))
    end
  end

  describe "an instance grant with a scope" do
    test "authorizes only while the record satisfies the scope" do
      draft = generate(post(status: :draft))
      published = generate(post(status: :published))

      assert {:ok, _} = update_as(draft, actor(["post:#{draft.id}:update:draft"]))

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(published, actor(["post:#{published.id}:update:draft"]))
    end

    test "a universal scope is unconditional" do
      post = generate(post(status: :published))
      assert {:ok, _} = update_as(post, actor(["post:#{post.id}:update:always"]))
    end

    test "an undeclared scope authorizes nothing and does not raise" do
      post = generate(post())

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(post, actor(["post:#{post.id}:update:no_such_scope"]))
    end
  end

  describe "instance_key" do
    test "an instance grant matches the configured key, not the primary key" do
      feed = generate(feed(feed_id: "feed_aaa"))

      assert {:ok, _} = update_as(feed, actor(["feed:feed_aaa:update:"]))

      assert {:error, %Ash.Error.Forbidden{}} =
               update_as(feed, actor(["feed:#{feed.id}:update:"]))
    end
  end

  describe "the union with RBAC and scope_through grants" do
    test "a failing RBAC scope does not hide an instance grant" do
      post = generate(post(author_id: Ash.UUID.generate()))

      assert {:ok, _} = update_as(post, actor(["post:*:update:own", "post:#{post.id}:update:"]))
    end

    test "a failing RBAC scope does not hide a scope_through parent grant" do
      post = generate(post())

      comment =
        Ash.create!(
          ChildComment,
          %{body: "b", post_id: post.id, user_id: Ash.UUID.generate()},
          action: :create,
          authorize?: false
        )

      actor = actor(["child_comment:*:update:own", "post:#{post.id}:update:"])

      assert {:ok, _} = update_as(comment, actor, %{body: "changed"})
    end
  end

  # The CHANGELOG's upgrade advice for parent grants issued for scope_through.
  describe "a parent grant issued for its scope_through children" do
    setup do
      post = generate(post())

      comment =
        Ash.create!(
          ChildComment,
          %{body: "b", post_id: post.id, user_id: Ash.UUID.generate()},
          action: :create,
          authorize?: false
        )

      %{post: post, comment: comment}
    end

    test "`*` now also writes the parent itself", %{post: post, comment: comment} do
      actor = actor(["post:#{post.id}:*:"])

      assert {:ok, _} = update_as(comment, actor, %{body: "changed"})
      assert {:ok, post} = update_as(post, actor)
      assert :ok = Ash.destroy(post, actor: actor)
    end

    test "RBAC denies on the parent keep the children writable", %{post: post, comment: comment} do
      actor =
        actor(["post:#{post.id}:*:", "!post:*:update:always", "!post:*:destroy:always"])

      assert {:ok, _} = update_as(comment, actor, %{body: "changed"})
      assert {:error, %Ash.Error.Forbidden{}} = update_as(post, actor)
      refute can_update?(Post, post, actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(post, actor: actor)
    end

    test "an instance deny on the parent also cancels the children's grant",
         %{post: post, comment: comment} do
      actor = actor(["post:#{post.id}:*:", "!post:#{post.id}:update:"])

      assert {:error, %Ash.Error.Forbidden{}} = update_as(comment, actor, %{body: "changed"})
      assert {:error, %Ash.Error.Forbidden{}} = update_as(post, actor)
    end
  end

  describe "CanPerform agrees with the runtime" do
    for grant <- ["update:", "*:"] do
      test "for `post:<id>:#{grant}`, on the record and off it" do
        post = generate(post())
        other = generate(post())
        actor = actor(["post:*:read:always", "post:#{post.id}:#{unquote(grant)}"])

        assert can_update?(Post, post, actor)
        assert {:ok, _} = update_as(post, actor)

        refute can_update?(Post, other, actor)
        assert {:error, %Ash.Error.Forbidden{}} = update_as(other, actor)
      end
    end
  end
end

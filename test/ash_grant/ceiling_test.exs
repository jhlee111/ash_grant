defmodule AshGrant.CeilingTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshGrant.{Introspect, PolicyTest.Checker}
  alias AshGrant.Test.CeilingPost

  defp actor(permissions, opts) do
    base = %{id: Keyword.get(opts, :id, Ash.UUID.generate()), permissions: permissions}

    case Keyword.fetch(opts, :ceiling) do
      {:ok, ceiling} -> Map.put(base, :ceiling, ceiling)
      :error -> base
    end
  end

  defp create!(attrs) do
    CeilingPost
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp read(actor) do
    CeilingPost
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp create(actor, attrs) do
    CeilingPost
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create()
  end

  defp update(actor, post) do
    post
    |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
    |> Ash.update()
  end

  defp destroy(actor, post) do
    post
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy()
  end

  setup do
    owner_id = Ash.UUID.generate()

    own = create!(%{title: "own", body: "own body", author_id: owner_id})

    other =
      create!(%{
        title: "other",
        body: "other body",
        status: :published,
        author_id: Ash.UUID.generate()
      })

    %{owner_id: owner_id, own: own, other: other}
  end

  describe "an owner with `own` grants and a read-only ceiling" do
    setup %{owner_id: owner_id} do
      %{
        key_actor:
          actor(["ceiling_post:*:*:own"], id: owner_id, ceiling: ["ceiling_post:*:read:always"])
      }
    end

    test "reads only their own posts", %{key_actor: key_actor, own: own} do
      assert read(key_actor) == MapSet.new([own.id])
    end

    test "cannot create, update or destroy", %{key_actor: key_actor, own: own, owner_id: owner_id} do
      assert {:error, %Ash.Error.Forbidden{}} =
               create(key_actor, %{title: "x", author_id: owner_id})

      assert {:error, %Ash.Error.Forbidden{}} = update(key_actor, own)
      assert {:error, %Ash.Error.Forbidden{}} = destroy(key_actor, own)
    end

    test "CanPerform agrees with the write check", %{key_actor: key_actor} do
      [post] = Ash.read!(CeilingPost, actor: key_actor, load: [:can_update?, :can_destroy?])

      refute post.can_update?
      refute post.can_destroy?
    end

    test "Introspect.can?/4 allows read and denies update", %{key_actor: key_actor} do
      assert {:allow, _} = Introspect.can?(CeilingPost, :read, key_actor)

      assert {:deny, %{reason: :denied_by_ceiling}} =
               Introspect.can?(CeilingPost, :update, key_actor)
    end

    test "Introspect.actor_permissions/3 reports update as not allowed", %{key_actor: key_actor} do
      statuses = Map.new(Introspect.actor_permissions(CeilingPost, key_actor), &{&1.action, &1})

      assert statuses["read"].allowed
      refute statuses["update"].allowed
      assert Introspect.ceiling_for(CeilingPost, key_actor) == ["ceiling_post:*:read:always"]
    end

    test "explain/4 denies update and names the ceiling", %{key_actor: key_actor} do
      explanation = AshGrant.explain(CeilingPost, :update, key_actor)

      assert explanation.decision == :deny
      assert explanation.reason == :denied_by_ceiling
      assert explanation.reason_code == :ceiling_denied
      assert %AshGrant.Explanation{decision: :deny} = explanation.ceiling
    end

    test "the policy test checker agrees", %{key_actor: key_actor, own: own, other: other} do
      assert {:allow, _} = Checker.check(CeilingPost, key_actor, :read, own)
      assert {:deny, _} = Checker.check(CeilingPost, key_actor, :read, other)
      assert {:deny, _} = Checker.check(CeilingPost, key_actor, :update, own)
    end
  end

  describe "an empty ceiling" do
    test "denies everything", %{owner_id: owner_id, own: own} do
      key_actor = actor(["ceiling_post:*:*:always"], id: owner_id, ceiling: [])

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(CeilingPost, actor: key_actor)
      assert {:error, %Ash.Error.Forbidden{}} = update(key_actor, own)
      assert {:deny, _} = Introspect.can?(CeilingPost, :read, key_actor)
    end
  end

  describe "no ceiling" do
    test "leaves the grants unchanged", %{owner_id: owner_id, own: own, other: other} do
      owner = actor(["ceiling_post:*:*:own", "ceiling_post:*:read:published"], id: owner_id)

      assert read(owner) == MapSet.new([own.id, other.id])
      assert {:ok, _} = update(owner, own)
      assert {:error, %Ash.Error.Forbidden{}} = update(owner, other)
      assert AshGrant.explain(CeilingPost, :update, owner).ceiling == nil
    end
  end

  describe "a ceiling never widens the grants" do
    test "a broad ceiling over narrow grants keeps the grants", %{
      owner_id: owner_id,
      own: own,
      other: other
    } do
      key_actor =
        actor(["ceiling_post:*:read:own"], id: owner_id, ceiling: ["ceiling_post:*:*:always"])

      assert read(key_actor) == MapSet.new([own.id])
      assert {:error, %Ash.Error.Forbidden{}} = update(key_actor, own)
      assert {:deny, _} = Checker.check(CeilingPost, key_actor, :read, other)
    end

    test "the ceiling's scope narrows the grants' scope", %{own: own, other: other} do
      key_actor =
        actor(["ceiling_post:*:read:always"], ceiling: ["ceiling_post:*:read:published"])

      assert read(key_actor) == MapSet.new([other.id])
      refute MapSet.member?(read(key_actor), own.id)
    end
  end

  describe "a deny in the ceiling" do
    test "beats an allow in the grants", %{own: own} do
      key_actor =
        actor(["ceiling_post:*:*:always"],
          ceiling: ["ceiling_post:*:*:always", "!ceiling_post:*:destroy:always"]
        )

      assert {:ok, updated} = update(key_actor, own)
      assert {:error, %Ash.Error.Forbidden{}} = destroy(key_actor, updated)

      assert {:deny, %{reason: :denied_by_ceiling}} =
               Introspect.can?(CeilingPost, :destroy, key_actor)
    end
  end

  describe "field groups" do
    test "a ceiling field group hides fields the grants show", %{own: own} do
      key_actor =
        actor(["ceiling_post:*:read:always"], ceiling: ["ceiling_post:*:read:always:summary"])

      post =
        CeilingPost
        |> Ash.Query.filter(id == ^own.id)
        |> Ash.read_one!(actor: key_actor)

      assert post.title == "own"
      assert %Ash.ForbiddenField{} = post.body
    end

    test "grants without a field group show every field when the ceiling has none", %{own: own} do
      key_actor = actor(["ceiling_post:*:read:always"], ceiling: ["ceiling_post:*:read:always"])

      post =
        CeilingPost
        |> Ash.Query.filter(id == ^own.id)
        |> Ash.read_one!(actor: key_actor)

      assert post.body == "own body"
    end
  end

  describe "AshGrant.Ceiling.resolve/3" do
    test "is nil for a function resolver" do
      assert AshGrant.Ceiling.resolve(fn _, _ -> [] end, %{ceiling: []}, %{}) == nil
    end

    test "is nil for a module without ceiling/2" do
      assert AshGrant.Ceiling.resolve(AshGrant.Test.NoLoadActorResolver, %{ceiling: []}, %{}) ==
               nil
    end
  end
end

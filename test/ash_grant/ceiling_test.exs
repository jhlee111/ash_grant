defmodule AshGrant.CeilingTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshGrant.{Introspect, PolicyTest.Checker}
  alias AshGrant.PolicyTest.Assertions
  alias AshGrant.Test.{CeilingComment, CeilingPost}

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

    own = create!(%{title: "own", body: "own body", notes: "own notes", author_id: owner_id})

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

    test "CanPerform agrees with the write check", %{key_actor: key_actor, own: own} do
      # authorize?: false skips field policies, which on Elixir 1.18 forbid the
      # generated can_*? calculations on a resource with default_field_policies.
      post =
        CeilingPost
        |> Ash.Query.filter(id == ^own.id)
        |> Ash.read_one!(
          actor: key_actor,
          authorize?: false,
          load: [:can_update?, :can_destroy?]
        )

      refute post.can_update?
      refute post.can_destroy?

      owner = Map.delete(key_actor, :ceiling)

      post =
        CeilingPost
        |> Ash.Query.filter(id == ^own.id)
        |> Ash.read_one!(actor: owner, authorize?: false, load: [:can_update?, :can_destroy?])

      assert post.can_update?
      assert post.can_destroy?
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

  describe "field groups in reporting" do
    setup do
      %{
        key_actor:
          actor(["ceiling_post:*:read:always:full"],
            ceiling: ["ceiling_post:*:read:always:summary"]
          )
      }
    end

    test "can?/4, explain/4 and actor_permissions/3 report the narrower group", %{
      key_actor: key_actor
    } do
      assert {:allow, %{field_groups: ["summary"]}} =
               Introspect.can?(CeilingPost, :read, key_actor)

      assert AshGrant.explain(CeilingPost, :read, key_actor).field_groups == ["summary"]

      statuses = Map.new(Introspect.actor_permissions(CeilingPost, key_actor), &{&1.action, &1})
      assert statuses["read"].field_groups == ["summary"]
    end

    test "policy test field assertions hide what the ceiling hides", %{key_actor: key_actor} do
      visible = Assertions.resolve_visible_fields(CeilingPost, key_actor, :read)

      assert :title in visible
      refute :body in visible
      refute :notes in visible
    end

    test "a ceiling without a field group leaves the grants' groups" do
      key_actor =
        actor(["ceiling_post:*:read:always:summary"], ceiling: ["ceiling_post:*:read:always"])

      assert {:allow, %{field_groups: ["summary"]}} =
               Introspect.can?(CeilingPost, :read, key_actor)
    end
  end

  describe "masking" do
    defp read_own(actor, own) do
      CeilingPost
      |> Ash.Query.filter(id == ^own.id)
      |> Ash.read_one!(actor: actor)
    end

    test "a masking group in the ceiling masks a field the grants show", %{own: own} do
      post =
        read_own(
          actor(["ceiling_post:*:read:always:full"],
            ceiling: ["ceiling_post:*:read:always:masked"]
          ),
          own
        )

      assert post.notes == "*********"
      assert %Ash.ForbiddenField{} = post.body
    end

    test "a masking group in the grants stays masked under a broader ceiling", %{own: own} do
      post =
        read_own(
          actor(["ceiling_post:*:read:always:masked"],
            ceiling: ["ceiling_post:*:read:always:full"]
          ),
          own
        )

      assert post.notes == "*********"
    end

    test "a masking ceiling masks grants with no field group", %{own: own} do
      post =
        read_own(
          actor(["ceiling_post:*:read:always"], ceiling: ["ceiling_post:*:read:always:masked"]),
          own
        )

      assert post.notes == "*********"
    end
  end

  describe "FieldCheck" do
    defp field_check?(actor, group) do
      authorizer = %{
        resource: CeilingPost,
        action: %{name: :read, type: :read},
        query: %{tenant: nil},
        changeset: nil
      }

      AshGrant.FieldCheck.match?(actor, authorizer, field_group: group)
    end

    test "requires the group in both lists" do
      key_actor =
        actor(["ceiling_post:*:read:always:full"],
          ceiling: ["ceiling_post:*:read:always:summary"]
        )

      assert field_check?(key_actor, :summary)
      refute field_check?(key_actor, :full)
      assert field_check?(Map.delete(key_actor, :ceiling), :full)
    end
  end

  describe "scope_through" do
    setup %{own: own, other: other} do
      on_own = create_comment!(own)
      on_other = create_comment!(other)
      %{on_own: on_own, on_other: on_other}
    end

    defp create_comment!(post) do
      CeilingComment
      |> Ash.Changeset.for_create(:create, %{body: "c", ceiling_post_id: post.id})
      |> Ash.create!(authorize?: false)
    end

    defp comment_ids(actor) do
      CeilingComment
      |> Ash.read!(actor: actor)
      |> MapSet.new(& &1.id)
    end

    test "a parent instance grant is capped by a child RBAC ceiling", %{
      own: own,
      on_own: on_own
    } do
      key_actor =
        actor(["ceiling_post:#{own.id}:read:"], ceiling: ["ceiling_comment:*:read:always"])

      assert comment_ids(key_actor) == MapSet.new([on_own.id])
      assert {:allow, _} = Introspect.can?(CeilingComment, :read, key_actor)

      statuses =
        Map.new(Introspect.actor_permissions(CeilingComment, key_actor), &{&1.action, &1})

      assert statuses["read"].allowed
    end

    test "a parent instance ceiling caps a child RBAC grant", %{own: own, on_own: on_own} do
      key_actor =
        actor(["ceiling_comment:*:read:always"], ceiling: ["ceiling_post:#{own.id}:read:"])

      assert comment_ids(key_actor) == MapSet.new([on_own.id])

      statuses =
        Map.new(Introspect.actor_permissions(CeilingComment, key_actor), &{&1.action, &1})

      assert statuses["read"].allowed
    end
  end

  describe "ResolveArgument" do
    setup %{own: own, other: other} do
      %{on_own: create_comment!(own), on_other: create_comment!(other)}
    end

    defp update_comment(actor, comment) do
      comment
      |> Ash.Changeset.for_update(:update, %{body: "changed"}, actor: actor)
      |> Ash.update()
    end

    test "resolves the argument when only the grants use a scope that needs it", %{
      owner_id: owner_id,
      on_own: on_own,
      on_other: on_other
    } do
      key_actor =
        actor(["ceiling_comment:*:update:on_own_post"],
          id: owner_id,
          ceiling: ["ceiling_comment:*:update:always"]
        )

      assert {:ok, _} = update_comment(key_actor, on_own)
      assert {:error, %Ash.Error.Forbidden{}} = update_comment(key_actor, on_other)
    end

    test "resolves the argument when only the ceiling uses a scope that needs it", %{
      owner_id: owner_id,
      on_own: on_own,
      on_other: on_other
    } do
      key_actor =
        actor(["ceiling_comment:*:update:always"],
          id: owner_id,
          ceiling: ["ceiling_comment:*:update:on_own_post"]
        )

      assert {:ok, _} = update_comment(key_actor, on_own)
      assert {:error, %Ash.Error.Forbidden{}} = update_comment(key_actor, on_other)
    end
  end

  describe "a malformed ceiling" do
    test "a non-list return raises an ArgumentError naming ceiling/2" do
      key_actor = actor(["ceiling_post:*:*:always"], ceiling: :everything)

      assert_raise ArgumentError, ~r/ceiling\/2 must return a list of permissions or nil/, fn ->
        Introspect.can?(CeilingPost, :read, key_actor)
      end

      refute match?({:ok, _}, safe_read(key_actor))
    end

    test "a raising ceiling fails closed" do
      key_actor =
        actor(["ceiling_post:*:*:always"], ceiling: fn -> raise "key store unavailable" end)

      refute match?({:ok, _}, safe_read(key_actor))
    end

    defp safe_read(actor) do
      Ash.read(CeilingPost, actor: actor)
    rescue
      error -> {:raised, error}
    end
  end

  describe "the policy test checker with a scope it cannot decide" do
    test "a ceiling that denies the action decides it", %{owner_id: owner_id, own: own} do
      key_actor =
        actor(["ceiling_post:*:*:titled_x"], id: owner_id, ceiling: ["ceiling_post:*:read:own"])

      assert {:deny, %{reason: :denied_by_ceiling}} =
               Checker.check(CeilingPost, key_actor, :update, own)

      assert {:indeterminate, _} = Checker.check(CeilingPost, key_actor, :read, own)
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

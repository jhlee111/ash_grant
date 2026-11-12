defmodule AshGrant.InstanceScopeReadTest do
  @moduledoc """
  A named scope on an instance permission (`post:<id>:read:draft`) narrows the
  grant: the record is reachable only while the scope holds for it (#207). An
  empty scope stays unconditional, an undeclared scope authorizes nothing without
  raising, and deny rules still win.

  Covers `FilterCheck` (through `Ash.read`), `CanPerform`, `FieldFilterCheck`,
  `AshGrant.explain/3` and the policy-test `Checker`.
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.PolicyTest.Checker
  alias AshGrant.Test.{CeilingPost, Feed, OwnedRecord, Post, TenantPost}

  defp actor(permissions), do: %{id: Ash.UUID.generate(), permissions: permissions}

  # A filter that resolves to `false` makes Ash raise Forbidden instead of
  # returning `[]`; both mean the actor sees nothing.
  defp read_ids(actor) do
    case Ash.read(Post, actor: actor) do
      {:ok, records} -> records |> Enum.map(& &1.id) |> Enum.sort()
      {:error, %Ash.Error.Forbidden{}} -> []
    end
  end

  defp explained_ids(explanation) do
    case explanation.scope_filter do
      nil ->
        []

      filter ->
        Post
        |> Ash.Query.do_filter(filter)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
        |> Enum.sort()
    end
  end

  defp record_map(record) do
    Map.take(record, Ash.Resource.Info.attribute_names(Post) |> Enum.to_list())
  end

  defp checker(record, actor) do
    Post |> Checker.check(actor, :read, record_map(record)) |> elem(0)
  end

  setup do
    %{draft: generate(post()), published: generate(published_post())}
  end

  describe "read filter" do
    test "a scoped instance grant returns the record only while the scope holds", %{
      draft: draft,
      published: published
    } do
      actor = actor(["post:#{draft.id}:read:draft", "post:#{published.id}:read:draft"])

      assert read_ids(actor) == [draft.id]
    end

    test "the record drops out of the result when it stops matching the scope", %{
      draft: draft
    } do
      actor = actor(["post:#{draft.id}:read:draft"])
      assert read_ids(actor) == [draft.id]

      draft
      |> Ash.Changeset.for_update(:publish, %{}, authorize?: false)
      |> Ash.update!()

      assert read_ids(actor) == []
    end

    test "an empty scope is unconditional", %{draft: draft, published: published} do
      actor = actor(["post:#{draft.id}:read:", "post:#{published.id}:read:"])

      assert read_ids(actor) == Enum.sort([draft.id, published.id])
    end

    test "a universal scope name is unconditional", %{published: published} do
      assert read_ids(actor(["post:#{published.id}:read:always"])) == [published.id]
    end

    test "an empty-scope grant on the same record outweighs a failing scoped one", %{
      published: published
    } do
      actor = actor(["post:#{published.id}:read:draft", "post:#{published.id}:read:"])

      assert read_ids(actor) == [published.id]
    end

    test "scoped and unscoped instance grants union with RBAC scopes", %{
      draft: draft,
      published: published
    } do
      other_draft = generate(post())

      actor =
        actor([
          "post:*:read:published",
          "post:#{draft.id}:read:draft",
          "post:#{other_draft.id}:read:published"
        ])

      assert read_ids(actor) == Enum.sort([draft.id, published.id])
    end

    test "an undeclared scope authorizes nothing and does not raise", %{draft: draft} do
      assert read_ids(actor(["post:#{draft.id}:read:no_such_scope_207"])) == []
    end

    test "an undeclared scope does not cancel a working grant", %{draft: draft} do
      actor = actor(["post:#{draft.id}:read:no_such_scope_207", "post:*:read:draft"])

      assert draft.id in read_ids(actor)
    end

    test "an instance deny wins over a scoped instance grant", %{draft: draft} do
      actor = actor(["post:#{draft.id}:read:draft", "!post:#{draft.id}:read:"])

      assert read_ids(actor) == []
    end

    test "an RBAC deny wins over a scoped instance grant", %{draft: draft} do
      actor = actor(["post:#{draft.id}:read:draft", "!post:*:read:always"])

      assert read_ids(actor) == []
    end

    test "a scoped instance deny cancels a grant with another scope on the same id", %{
      draft: draft
    } do
      actor = actor(["post:#{draft.id}:read:draft", "!post:#{draft.id}:read:published"])

      assert read_ids(actor) == []
    end

    test "two named scopes on one id admit the record where either holds", %{
      draft: draft,
      published: published
    } do
      grants = fn id -> ["post:#{id}:read:draft", "post:#{id}:read:published"] end
      actor = actor(grants.(draft.id) ++ grants.(published.id))

      assert read_ids(actor) == Enum.sort([draft.id, published.id])
    end

    test "an undeclared scope beside a failing named scope on one id admits nothing", %{
      published: published
    } do
      actor =
        actor(["post:#{published.id}:read:draft", "post:#{published.id}:read:no_such_scope_207"])

      assert read_ids(actor) == []
    end

    test "an inherited scope applies its parent's condition", %{draft: draft} do
      own = generate(post(author_id: draft.author_id, status: :published))
      someone_elses = generate(post())

      permissions =
        Enum.map([draft, own, someone_elses], &"post:#{&1.id}:read:own_draft")

      assert read_ids(%{id: draft.author_id, permissions: permissions}) == [draft.id]
    end

    test "existing atoms that are not scopes authorize nothing", %{draft: draft} do
      for scope <- ["nil", "true", "false", "status", "id"] do
        assert read_ids(actor(["post:#{draft.id}:read:#{scope}"])) == [],
               "scope #{inspect(scope)} admitted the record"
      end
    end

    test "a scope applies against a non-default instance_key" do
      draft = generate(feed())
      published = generate(feed(status: :published))
      actor = actor(Enum.map([draft, published], &"feed:#{&1.feed_id}:read:published"))

      assert Feed |> Ash.read!(actor: actor) |> Enum.map(& &1.id) == [published.id]
    end

    test "a ^tenant() scope admits the record only in its tenant" do
      tenant = Ash.UUID.generate()

      post =
        TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "t", tenant_id: tenant}, authorize?: false)
        |> Ash.create!()

      actor = actor(["tenant_post:#{post.id}:read:same_tenant"])

      assert TenantPost |> Ash.read!(actor: actor, tenant: tenant) |> Enum.map(& &1.id) == [
               post.id
             ]

      assert TenantPost |> Ash.read!(actor: actor, tenant: Ash.UUID.generate()) == []
    end
  end

  describe "under a ceiling" do
    defp ceiling_post!(status) do
      CeilingPost
      |> Ash.Changeset.for_create(:create, %{title: "t", status: status}, authorize?: false)
      |> Ash.create!()
    end

    defp ceiling_read_ids(actor) do
      case Ash.read(CeilingPost, actor: actor) do
        {:ok, records} -> records |> Enum.map(& &1.id) |> Enum.sort()
        {:error, %Ash.Error.Forbidden{}} -> []
      end
    end

    test "a scoped instance grant in the ceiling narrows an RBAC grant" do
      draft = ceiling_post!(:draft)
      published = ceiling_post!(:published)

      ceiling = Enum.map([draft, published], &"ceiling_post:#{&1.id}:read:published")
      actor = %{id: Ash.UUID.generate(), permissions: ["ceiling_post:*:read:always"]}

      assert ceiling_read_ids(Map.put(actor, :ceiling, ceiling)) == [published.id]
    end

    test "a scoped instance grant is narrowed by an RBAC ceiling" do
      draft = ceiling_post!(:draft)
      published = ceiling_post!(:published)

      actor = %{
        id: Ash.UUID.generate(),
        permissions: Enum.map([draft, published], &"ceiling_post:#{&1.id}:read:published"),
        ceiling: ["ceiling_post:*:read:always"]
      }

      assert ceiling_read_ids(actor) == [published.id]
    end

    test "an undeclared instance scope in the ceiling allows nothing" do
      post = ceiling_post!(:published)

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["ceiling_post:*:read:always"],
        ceiling: ["ceiling_post:#{post.id}:read:no_such_scope_207"]
      }

      assert ceiling_read_ids(actor) == []
    end
  end

  describe "CanPerform" do
    defp can_update_by_id(actor) do
      Post
      |> Ash.Query.load(:can_update?)
      |> Ash.read!(actor: actor)
      |> Map.new(&{&1.id, &1.can_update?})
    end

    test "a scoped instance grant is true only where the scope holds", %{
      draft: draft,
      published: published
    } do
      actor =
        actor([
          "post:*:read:always",
          "post:#{draft.id}:update:draft",
          "post:#{published.id}:update:draft"
        ])

      can = can_update_by_id(actor)

      assert can[draft.id] == true
      assert can[published.id] == false
    end

    test "an undeclared scope is false and does not raise", %{draft: draft} do
      actor = actor(["post:*:read:always", "post:#{draft.id}:update:no_such_scope_207"])

      assert can_update_by_id(actor)[draft.id] == false
    end

    test "an actor-template scope holds only for the actor's own records", %{draft: draft} do
      someone_elses = generate(post())

      permissions =
        ["post:*:read:always"] ++ Enum.map([draft, someone_elses], &"post:#{&1.id}:update:own")

      can = can_update_by_id(%{id: draft.author_id, permissions: permissions})

      assert can[draft.id] == true
      assert can[someone_elses.id] == false
    end

    test "a scope applies against a non-default instance_key" do
      draft = generate(feed())
      published = generate(feed(status: :published))

      permissions =
        ["feed:*:read:always"] ++
          Enum.map([draft, published], &"feed:#{&1.feed_id}:update:published")

      can =
        Feed
        |> Ash.Query.load(:can_update?)
        |> Ash.read!(actor: actor(permissions))
        |> Map.new(&{&1.id, &1.can_update?})

      assert can[published.id] == true
      assert can[draft.id] == false
    end
  end

  describe "field visibility" do
    defp owned_record!(owner_id) do
      OwnedRecord
      |> Ash.Changeset.for_create(
        :create,
        %{owner_id: owner_id, title: "t", secret: "s"},
        authorize?: false
      )
      |> Ash.create!()
    end

    defp secret_visible?(record, actor) do
      OwnedRecord
      |> Ash.read!(actor: actor)
      |> Enum.find(&(&1.id == record.id))
      |> Map.fetch!(:secret)
      |> then(&(not match?(%Ash.ForbiddenField{}, &1)))
    end

    test "a scoped instance field-group grant shows the field only where the scope holds" do
      record = owned_record!("u1")

      permissions = [
        "ownedrecord:*:read:always:public",
        "ownedrecord:#{record.id}:read:own:sensitive"
      ]

      assert secret_visible?(record, %{id: "u1", permissions: permissions})
      refute secret_visible?(record, %{id: "u2", permissions: permissions})
    end

    test "an undeclared scope hides the field" do
      record = owned_record!("u1")

      permissions = [
        "ownedrecord:*:read:always:public",
        "ownedrecord:#{record.id}:read:no_such_scope_207:sensitive"
      ]

      refute secret_visible?(record, %{id: "u1", permissions: permissions})
    end

    test "an instance deny hides the field" do
      record = owned_record!("u1")

      permissions = [
        "ownedrecord:*:read:always:public",
        "ownedrecord:#{record.id}:read:own:sensitive",
        "!ownedrecord:#{record.id}:read:"
      ]

      refute Enum.any?(
               OwnedRecord |> Ash.read!(actor: %{id: "u1", permissions: permissions}),
               &(&1.id == record.id and not match?(%Ash.ForbiddenField{}, &1.secret))
             )
    end
  end

  describe "AshGrant.explain/3" do
    test "the scope filter narrows a scoped instance grant", %{
      draft: draft,
      published: published
    } do
      actor = actor(["post:#{draft.id}:read:draft", "post:#{published.id}:read:draft"])
      explanation = AshGrant.explain(Post, :read, actor)

      assert explained_ids(explanation) == read_ids(actor)
      assert explained_ids(explanation) == [draft.id]
    end

    test "a scoped instance grant's reason names its scope", %{draft: draft} do
      grant = "post:#{draft.id}:read:draft"
      explanation = AshGrant.explain(Post, :read, actor([grant]))

      assert explanation.decision == :allow
      entry = Enum.find(explanation.evaluated_permissions, &(&1.permission == grant))
      assert %{matched: true, reason: reason} = entry
      assert reason =~ "while scope `draft` holds"
    end

    test "an undeclared scope is unmatched and the decision is deny", %{draft: draft} do
      grant = "post:#{draft.id}:read:no_such_scope_207"
      actor = actor([grant])
      explanation = AshGrant.explain(Post, :read, actor)

      assert explanation.decision == :deny
      assert explanation.reason_code == :no_matching_permission
      assert read_ids(actor) == []

      entry = Enum.find(explanation.evaluated_permissions, &(&1.permission == grant))
      assert %{matched: false, reason: "Scope `no_such_scope_207` is not declared" <> _} = entry
    end

    test "an undeclared scope beside a working grant leaves the decision allow", %{
      draft: draft
    } do
      actor = actor(["post:#{draft.id}:read:no_such_scope_207", "post:#{draft.id}:read:"])
      explanation = AshGrant.explain(Post, :read, actor)

      assert explanation.decision == :allow
      assert explained_ids(explanation) == read_ids(actor)
    end
  end

  describe "policy-test Checker" do
    test "agrees with the runtime on a scoped instance grant", %{
      draft: draft,
      published: published
    } do
      actor = actor(["post:#{draft.id}:read:draft", "post:#{published.id}:read:draft"])

      assert checker(draft, actor) == :allow
      assert checker(published, actor) == :deny
    end

    test "an empty scope admits the record", %{published: published} do
      assert checker(published, actor(["post:#{published.id}:read:"])) == :allow
    end

    test "an undeclared scope admits nothing", %{draft: draft} do
      assert checker(draft, actor(["post:#{draft.id}:read:no_such_scope_207"])) == :deny
    end

    test "a universal scope admits the record", %{draft: draft} do
      assert checker(draft, actor(["post:#{draft.id}:read:always"])) == :allow
    end

    test "a scoped instance deny wins over a scoped grant", %{draft: draft} do
      actor = actor(["post:#{draft.id}:read:draft", "!post:#{draft.id}:read:published"])

      assert checker(draft, actor) == :deny
    end

    test "a scope it cannot evaluate in memory is undecided", %{draft: draft} do
      assert {:indeterminate, _} =
               Checker.check(
                 Post,
                 actor(["post:#{draft.id}:read:today"]),
                 :read,
                 record_map(draft)
               )
    end
  end
end

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
  alias AshGrant.Test.{OwnedRecord, Post}

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
  end
end

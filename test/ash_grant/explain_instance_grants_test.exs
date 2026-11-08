defmodule AshGrant.ExplainInstanceGrantsTest do
  @moduledoc """
  `AshGrant.explain/4` must agree with the runtime on instance grants (#208).

  Each test reads through the policies, then checks the explanation's decision,
  and that its `scope_filter`, applied without authorization, selects the same
  rows the runtime returned.
  """
  use AshGrant.DataCase, async: false

  alias AshGrant.Test.{ChildComment, Post}

  setup do
    post = Ash.Seed.seed!(Post, %{title: "mine", status: :published})
    other = Ash.Seed.seed!(Post, %{title: "other", status: :published})
    %{post: post, other: other}
  end

  defp actor(permissions), do: %{id: Ash.UUID.generate(), permissions: permissions}

  defp runtime_ids(resource, actor) do
    case Ash.read(resource, actor: actor) do
      {:ok, records} -> records |> Enum.map(& &1.id) |> Enum.sort()
      {:error, %Ash.Error.Forbidden{}} -> :forbidden
    end
  end

  defp explained_ids(resource, %{scope_filter: filter}) do
    resource
    |> Ash.Query.do_filter(filter)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp entry(explanation, permission),
    do: Enum.find(explanation.evaluated_permissions, &(&1.permission == permission))

  describe "the resource's own instance grants" do
    test "an instance-only grant is allowed and filters to that record", %{post: post} do
      grant = "post:#{post.id}:read:"
      actor = actor([grant])
      explanation = AshGrant.explain(Post, :read, actor)

      assert runtime_ids(Post, actor) == [post.id]
      assert explanation.decision == :allow
      assert explanation.reason_code == :allow_matched
      assert explanation.summary =~ "Allowed by '#{grant}'"
      assert %{matched: true, reason: "Grants instance " <> _} = entry(explanation, grant)
      assert explained_ids(Post, explanation) == [post.id]
    end

    test "a type-wildcard instance grant counts, as it does on the read filter", %{post: post} do
      actor = actor(["post:#{post.id}:@read:"])
      explanation = AshGrant.explain(Post, :read, actor)

      assert runtime_ids(Post, actor) == [post.id]
      assert explanation.decision == :allow
      assert explained_ids(Post, explanation) == [post.id]
    end

    test "an instance deny cancels the instance grant on the same record", %{post: post} do
      grant = "post:#{post.id}:read:"
      deny = "!post:#{post.id}:read:"
      explanation = AshGrant.explain(Post, :read, actor([grant, deny]))

      assert runtime_ids(Post, actor([grant, deny])) == :forbidden
      assert explanation.decision == :deny
      assert explanation.reason_code == :no_matching_permission

      assert %{matched: false, reason: "Cancelled by an instance deny" <> _} =
               entry(explanation, grant)

      assert %{matched: true, reason: "Excludes instance " <> _} = entry(explanation, deny)
    end

    test "an instance deny narrows an RBAC grant's filter", %{post: post, other: other} do
      actor = actor(["post:*:read:always", "!post:#{post.id}:read:"])
      explanation = AshGrant.explain(Post, :read, actor)

      assert explanation.decision == :allow
      assert runtime_ids(Post, actor) == [other.id]
      assert explained_ids(Post, explanation) == [other.id]
    end

    test "instance and RBAC grants are ORed", %{post: post, other: other} do
      actor = actor(["post:*:read:draft", "post:#{post.id}:read:"])
      explanation = AshGrant.explain(Post, :read, actor)

      assert explanation.decision == :allow
      assert runtime_ids(Post, actor) == [post.id]
      assert explained_ids(Post, explanation) == [post.id]
      refute other.id in explained_ids(Post, explanation)
    end
  end

  describe "scope_through" do
    test "a parent instance grant reaches the child", %{post: post, other: other} do
      comment = Ash.Seed.seed!(ChildComment, %{body: "on mine", post_id: post.id})
      Ash.Seed.seed!(ChildComment, %{body: "on other", post_id: other.id})

      grant = "post:#{post.id}:read:"
      actor = actor([grant])
      explanation = AshGrant.explain(ChildComment, :read, actor)

      assert runtime_ids(ChildComment, actor) == [comment.id]
      assert explanation.decision == :allow
      assert %{matched: true, reason: reason} = entry(explanation, grant)
      assert reason =~ "via scope_through :post"
      assert explained_ids(ChildComment, explanation) == [comment.id]
    end
  end

  describe "RBAC grants" do
    test "a grant without a scope authorizes nothing, as at runtime" do
      grant = "post:*:read:"
      actor = actor([grant])
      explanation = AshGrant.explain(Post, :read, actor)

      assert runtime_ids(Post, actor) == :forbidden
      assert explanation.decision == :deny
      assert %{matched: false, reason: "No scope" <> _} = entry(explanation, grant)
    end

    test "an RBAC deny is still the deny the summary names", %{post: post} do
      actor = actor(["!post:#{post.id}:read:", "post:*:read:always", "!post:*:read:always"])
      explanation = AshGrant.explain(Post, :read, actor)

      assert runtime_ids(Post, actor) == :forbidden
      assert explanation.decision == :deny
      assert explanation.reason_code == :deny_rule_matched
      assert explanation.summary == "Denied by '!post:*:read:always' (deny rule)."
    end
  end
end

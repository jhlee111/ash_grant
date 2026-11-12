defmodule AshGrant.ExplanationSummaryTest do
  @moduledoc """
  Tests for Explanation's human/LLM-readable fields: `summary`,
  `reason_code`, and `scope_filter_string`.

  These fields are the first thing downstream consumers (Phoenix
  dashboard, AI agents) read. They must be:
  - always populated (no nil summary for a valid evaluation)
  - structured enough to branch on programmatically (`reason_code`)
  - readable enough to show verbatim in a UI or LLM response (`summary`)
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.Post

  describe "reason_code" do
    test "is :allow_matched when an allow permission grants access" do
      actor = %{id: "user_1", permissions: ["post:*:read:always"]}
      %{reason_code: code} = AshGrant.explain(Post, :read, actor)
      assert code == :allow_matched
    end

    test "is :deny_rule_matched when a deny permission wins" do
      actor = %{
        id: "user_1",
        permissions: ["post:*:*:always", "!post:*:destroy:always"]
      }

      %{reason_code: code} = AshGrant.explain(Post, :destroy, actor)
      assert code == :deny_rule_matched
    end

    test "is :no_matching_permission when no rule matches" do
      actor = %{id: "user_1", permissions: []}
      %{reason_code: code} = AshGrant.explain(Post, :read, actor)
      assert code == :no_matching_permission
    end

    test "is :no_matching_permission when actor is nil" do
      %{reason_code: code} = AshGrant.explain(Post, :read, nil)
      assert code == :no_matching_permission
    end
  end

  describe "summary" do
    test "for allow, mentions the matched permission string" do
      actor = %{id: "user_1", permissions: ["post:*:read:always"]}
      %{summary: summary} = AshGrant.explain(Post, :read, actor)

      assert is_binary(summary)
      assert summary =~ "post:*:read:always"
      assert summary =~ ~r/allow/i
    end

    test "for deny by rule, mentions the deny permission" do
      actor = %{
        id: "user_1",
        permissions: ["post:*:*:always", "!post:*:destroy:always"]
      }

      %{summary: summary} = AshGrant.explain(Post, :destroy, actor)

      assert is_binary(summary)
      assert summary =~ "!post:*:destroy:always"
      assert summary =~ ~r/den(y|ied)/i
    end

    test "for no match, states that no permission matched" do
      actor = %{id: "user_1", permissions: []}
      %{summary: summary} = AshGrant.explain(Post, :read, actor)

      assert is_binary(summary)
      assert summary =~ ~r/no.*match|no.*permission/i
    end

    test "is always a non-empty string" do
      cases = [
        {nil, :read},
        {%{id: "user_1", permissions: []}, :read},
        {%{id: "user_1", permissions: ["post:*:read:always"]}, :read},
        {%{id: "user_1", permissions: ["post:*:*:always", "!post:*:destroy:always"]}, :destroy}
      ]

      for {actor, action} <- cases do
        %{summary: summary} = AshGrant.explain(Post, action, actor)
        assert is_binary(summary) and byte_size(summary) > 0
      end
    end
  end

  describe "scope_filter_string" do
    test "is populated when allow applies a scope" do
      actor = %{id: "user_1", permissions: ["post:*:update:own"]}
      %{scope_filter_string: str} = AshGrant.explain(Post, :update, actor)

      assert is_binary(str)
      assert str =~ "^actor(:id)"
      refute str =~ ":_actor"
    end

    test "mirrors ExprStringify output of scope_filter" do
      actor = %{id: "user_1", permissions: ["post:*:update:own"]}
      exp = AshGrant.explain(Post, :update, actor)

      assert exp.scope_filter_string == AshGrant.ExprStringify.to_string(exp.scope_filter)
    end

    test "is nil when decision is deny" do
      %{scope_filter_string: str} = AshGrant.explain(Post, :read, nil)
      assert str == nil
    end
  end

  describe "Jason encoding integration" do
    test "JSON output includes summary and reason_code as strings" do
      actor = %{id: "user_1", permissions: ["post:*:read:always"]}

      decoded =
        Post
        |> AshGrant.explain(:read, actor)
        |> Jason.encode!()
        |> Jason.decode!()

      assert is_binary(decoded["summary"])
      assert decoded["reason_code"] == "allow_matched"
    end
  end

  describe "String.Chars" do
    test "interpolates as the plain-text report, without ANSI colors" do
      actor = %{id: "user_1", permissions: ["post:*:read:always"]}
      explanation = AshGrant.explain(Post, :read, actor)

      text = "#{explanation}"

      assert text == AshGrant.Explanation.to_string(explanation, color: false)
      assert text =~ "ALLOW"
      refute text =~ "\e["
    end
  end
end

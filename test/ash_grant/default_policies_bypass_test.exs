defmodule AshGrant.DefaultPoliciesBypassTest do
  @moduledoc """
  A resource that declares `default_policies true` alongside a user-defined
  `bypass` must let the bypass short-circuit before the generated strict
  write policy denies. The AshAuthentication sign-in flow is the motivating
  case: a sign-in action runs before there is an actor, so the write check
  would otherwise forbid it.
  """

  use ExUnit.Case, async: true

  alias Ash.Policy.Info
  alias AshGrant.Test.{ArticleForbidBeforeBypass, ArticleWithBypass, ArticleWithPolicyGroup}

  describe "default_policies true alongside a bypass" do
    test "bypass is evaluated before the generated write policy" do
      policies = Info.policies(ArticleWithBypass)

      assert [first | _] = policies

      assert first.bypass?,
             "expected the user-declared bypass to come first, got #{inspect(policies)}"
    end

    test "bypass short-circuits a write action for an anonymous actor" do
      assert {:ok, record} =
               Ash.create(ArticleWithBypass, %{name: "sign-in"},
                 action: :sign_in,
                 actor: nil,
                 authorize?: true,
                 context: %{stub_bypass: true}
               )

      assert record.name == "sign-in"
    end

    test "without the bypass hit, the generated write policy still denies an anonymous actor" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(ArticleWithBypass, %{name: "nope"},
                 action: :create,
                 actor: nil,
                 authorize?: true
               )
    end
  end

  describe "default_policies true keeps the user's policies as declared" do
    test "a forbid policy declared before a bypass still forbids" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(ArticleForbidBeforeBypass, %{}, actor: %{id: 1}, authorize?: true)
    end

    test "the generated policies come after the user's policies" do
      assert [forbid, bypass | _] = Info.policies(ArticleForbidBeforeBypass)
      assert [%{type: :forbid_if}] = forbid.policies
      assert bypass.bypass?
    end

    test "a policy_group compiles and its actions still authorize" do
      assert {:ok, _} =
               Ash.create(ArticleWithPolicyGroup, %{}, actor: %{id: 1}, authorize?: true)
    end
  end
end

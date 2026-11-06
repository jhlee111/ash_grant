defmodule AshGrant.FilterCheckPolicyBreakdownTest do
  @moduledoc """
  `Ash.Error.Forbidden.Policy.report/2` renders the policy breakdown that
  `config :ash, :policies, show_policy_breakdowns?: true` adds to a forbidden
  error's message. It describes each check with an authorizer that carries
  the query but no action.
  """
  use AshGrant.DataCase, async: true

  alias Ash.Error.Forbidden.Policy
  alias AshGrant.Test.Article

  test "the policy breakdown of a read forbidden by AshGrant.FilterCheck renders" do
    assert {:error, %Ash.Error.Forbidden{errors: [%Policy{} = policy_error]}} =
             Ash.read(Article, actor: %{role: :nobody})

    assert Policy.report(policy_error, help_text?: false) =~
             "authorize if: has permission filter"
  end
end

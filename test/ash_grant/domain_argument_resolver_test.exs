defmodule AshGrant.DomainArgumentResolverTest do
  @moduledoc """
  Regression for #147: a `resolve_argument` whose only referencing scope is
  domain-inherited must compile (no false "no scope references" error and no
  compile deadlock) and must be registered domain-aware.
  """
  use ExUnit.Case, async: true

  alias AshGrant.ArgumentAnalyzer
  alias AshGrant.Test.ArgResolverDomain
  alias AshGrant.Test.DomainArgPost

  test "resource + domain pair compiles without a cycle or a false error" do
    # The domain declares a `code_interface` entry targeting the resource —
    # the combination that deadlocked under the pre-v0.20 transformer merge.
    assert Code.ensure_loaded?(DomainArgPost)
    assert Code.ensure_loaded?(ArgResolverDomain)
  end

  test "a domain-inherited scope referencing ^arg(:center_id) is registered" do
    arg_map = ArgumentAnalyzer.arg_to_scopes(DomainArgPost)

    # :at_own_unit comes from the domain, not the resource.
    assert arg_map[:center_id] == [:at_own_unit]
  end

  test "the resource's own scopes are still merged with domain scopes" do
    names = DomainArgPost |> AshGrant.Info.scopes() |> Enum.map(& &1.name)

    assert :always in names
    assert :at_own_unit in names
  end
end

defmodule AshGrant.CodeInterfaceCycleTest do
  @moduledoc """
  Regression: a resource using `AshGrant` paired with a domain that uses
  `AshGrant.Domain` AND declares a `code_interface do define … end` block
  must compile. Before the runtime-merge fix this combination deadlocked
  during compilation.

  These tests verify both that the pair compiles AND that the merged
  resolver/scopes are visible at runtime.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Info
  alias AshGrant.Test.CodeInterfaceCycleDomain
  alias AshGrant.Test.CodeInterfaceCyclePost

  describe "compile" do
    test "resource compiles when domain has AshGrant.Domain + code_interface" do
      assert Code.ensure_loaded?(CodeInterfaceCyclePost)
      assert Code.ensure_loaded?(CodeInterfaceCycleDomain)
    end

    test "domain code_interface is generated" do
      assert function_exported?(
               CodeInterfaceCycleDomain,
               :create_code_interface_cycle_post,
               1
             )

      assert function_exported?(
               CodeInterfaceCycleDomain,
               :read_code_interface_cycle_post,
               0
             )
    end
  end

  describe "runtime merge" do
    test "resolver is inherited from the domain" do
      resolver = Info.resolver(CodeInterfaceCyclePost)
      assert is_function(resolver, 2)
      assert resolver.(%{permissions: ["x"]}, %{}) == ["x"]
    end

    test "scopes are inherited from the domain" do
      names =
        CodeInterfaceCyclePost
        |> Info.scopes()
        |> Enum.map(& &1.name)

      assert :always in names
      assert :own in names
    end

    test "configured?/1 returns true via domain fallback" do
      assert Info.configured?(CodeInterfaceCyclePost)
    end
  end

  describe "end-to-end authorization" do
    test "read via domain code_interface succeeds with :always permission" do
      id = Ash.UUID.generate()
      actor = %{id: id, permissions: ["code_interface_cycle_post:*:read:always"]}

      CodeInterfaceCyclePost
      |> Ash.Changeset.for_create(:create, %{title: "A", author_id: id}, authorize?: false)
      |> Ash.create!()

      assert [_ | _] = CodeInterfaceCycleDomain.read_code_interface_cycle_post!(actor: actor)
    end
  end
end

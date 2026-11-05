defmodule AshGrant.ScopeRegistryTest do
  # Not async: the registry is looked up through `Application.get_env`, which
  # is a global the suite shares. Flipping it on/off inside a parallel run
  # would be seen by any other test that reads `AshGrant.Info.scopes/1`.
  use ExUnit.Case, async: false

  alias AshGrant.Info
  alias AshGrant.PermissionValidation

  alias AshGrant.Test.GlobalScopes
  alias AshGrant.Test.RegistryDomainOverridePost
  alias AshGrant.Test.RegistryOnlyPost
  alias AshGrant.Test.RegistryResourceOverridePost

  setup do
    previous = Application.get_env(:ash_grant, :scope_registry)
    Application.put_env(:ash_grant, :scope_registry, GlobalScopes)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ash_grant, :scope_registry)
        other -> Application.put_env(:ash_grant, :scope_registry, other)
      end
    end)

    :ok
  end

  describe "AshGrant.ScopeRegistry" do
    test "scopes/0 reads the configured registry" do
      names = AshGrant.ScopeRegistry.scopes() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:always, :own, :registry_only]

      assert %AshGrant.Dsl.Scope{filter: true} =
               Enum.find(AshGrant.ScopeRegistry.scopes(), &(&1.name == :always))
    end

    test "scopes/0 returns [] when no registry is configured" do
      Application.delete_env(:ash_grant, :scope_registry)
      assert AshGrant.ScopeRegistry.scopes() == []
    end
  end

  describe "Info.scopes/1 merging" do
    test "resource with no local scopes picks up registry scopes" do
      names = Info.scopes(RegistryOnlyPost) |> Enum.map(& &1.name) |> MapSet.new()

      assert :always in names
      assert :own in names
      assert :registry_only in names
    end

    test "resource scope wins over a registry scope with the same name" do
      own = Info.get_scope(RegistryResourceOverridePost, :own)
      assert own

      # The resource's :own references resource_author_id; the registry's uses author_id.
      refute Info.scopes(RegistryResourceOverridePost)
             |> Enum.count(&(&1.name == :own)) > 1

      filter_source = Macro.to_string(Macro.escape(own.filter))
      assert filter_source =~ "resource_author_id"
      refute filter_source =~ "\"author_id\""
    end

    test "domain scope wins over a registry scope with the same name" do
      own = Info.get_scope(RegistryDomainOverridePost, :own)
      assert own

      filter_source = Macro.to_string(Macro.escape(own.filter))
      assert filter_source =~ "domain_author_id"
    end

    test "no registry configured leaves behaviour unchanged" do
      Application.delete_env(:ash_grant, :scope_registry)

      names = Info.scopes(RegistryOnlyPost) |> Enum.map(& &1.name) |> MapSet.new()

      # :own still comes from the domain; :always and :registry_only were
      # registry-only and must be gone now.
      refute :always in names
      refute :registry_only in names
    end
  end

  describe "PermissionValidation" do
    test "a permission using a registry-only scope passes validation" do
      issues =
        PermissionValidation.check(
          "registry_only_post:*:read:registry_only",
          resources: [RegistryOnlyPost]
        )

      refute PermissionValidation.errors?(issues),
             "expected no errors, got: #{inspect(issues)}"
    end

    test "an unknown scope still fails validation" do
      issues =
        PermissionValidation.check(
          "registry_only_post:*:read:does_not_exist",
          resources: [RegistryOnlyPost]
        )

      assert PermissionValidation.errors?(issues)
    end
  end
end

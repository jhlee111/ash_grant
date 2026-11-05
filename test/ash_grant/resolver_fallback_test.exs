defmodule AshGrant.ResolverFallbackTest do
  # Not async: the fallback is looked up through `Application.get_env`, which
  # is a global the suite shares. Flipping it on/off inside a parallel run
  # would be seen by any other test that reads `AshGrant.Info.resolver/1`.
  use ExUnit.Case, async: false

  alias AshGrant.Info

  alias AshGrant.Test.ResolverFallbackDomainOverridePost
  alias AshGrant.Test.ResolverFallbackDomainResolver
  alias AshGrant.Test.ResolverFallbackOnlyPost
  alias AshGrant.Test.ResolverFallbackResolver
  alias AshGrant.Test.ResolverFallbackResourceOverridePost
  alias AshGrant.Test.ResolverFallbackResourceResolver

  setup do
    previous = Application.get_env(:ash_grant, :resolver)
    Application.put_env(:ash_grant, :resolver, ResolverFallbackResolver)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ash_grant, :resolver)
        other -> Application.put_env(:ash_grant, :resolver, other)
      end
    end)

    :ok
  end

  describe "Info.resolver/1 precedence" do
    test "resource with no resolver and domain with no resolver picks up app config" do
      assert Info.resolver(ResolverFallbackOnlyPost) == ResolverFallbackResolver
    end

    test "returns nil when no resolver is configured at any level" do
      Application.delete_env(:ash_grant, :resolver)
      assert Info.resolver(ResolverFallbackOnlyPost) == nil
    end

    test "domain resolver wins over app config" do
      assert Info.resolver(ResolverFallbackDomainOverridePost) ==
               ResolverFallbackDomainResolver
    end

    test "resource resolver wins over app config" do
      assert Info.resolver(ResolverFallbackResourceOverridePost) ==
               ResolverFallbackResourceResolver
    end

    test "resource resolver wins over domain resolver (unchanged)" do
      # Sanity check: the pre-existing resource > domain precedence still
      # holds with the app-config fallback in place.
      assert Info.resolver(ResolverFallbackResourceOverridePost) ==
               ResolverFallbackResourceResolver
    end
  end

  describe "AshGrant.check runtime" do
    test "authorizes successfully when only the app-config resolver is set" do
      {:ok, _result} =
        ResolverFallbackOnlyPost
        |> Ash.Query.for_read(:read)
        |> Ash.read(actor: %{id: Ecto.UUID.generate()})
    end
  end
end

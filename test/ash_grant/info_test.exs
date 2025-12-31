defmodule AshGrant.InfoTest do
  @moduledoc """
  Tests for AshGrant.Info DSL introspection module.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Info

  # Test resource with full configuration
  defmodule FullConfigResource do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver fn actor, _context ->
        if actor, do: ["resource:*:read:all"], else: []
      end

      resource_name "custom_resource"

      scope :all, true
      scope :own, expr(owner_id == ^actor(:id))
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :owner_id, :uuid
    end
  end

  # Test resource with minimal configuration
  defmodule MinimalConfigResource do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver fn _actor, _context -> [] end
    end

    attributes do
      uuid_primary_key :id
    end
  end

  # Test resource with module-based resolver
  defmodule TestResolver do
    @behaviour AshGrant.PermissionResolver

    @impl true
    def resolve(_actor, _context), do: ["test:*:read:all"]
  end

  defmodule ModuleResolverResource do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver AshGrant.InfoTest.TestResolver
    end

    attributes do
      uuid_primary_key :id
    end
  end

  describe "resolver/1" do
    test "returns function resolver" do
      resolver = Info.resolver(FullConfigResource)
      assert is_function(resolver, 2)
    end

    test "returns module resolver" do
      resolver = Info.resolver(ModuleResolverResource)
      assert resolver == TestResolver
    end

    test "returns nil for resource without ash_grant" do
      # This would require a resource without the extension
      # Skip for now as it requires different test setup
    end
  end

  describe "resource_name/1" do
    test "returns configured resource name" do
      name = Info.resource_name(FullConfigResource)
      assert name == "custom_resource"
    end

    test "derives resource name from module when not configured" do
      name = Info.resource_name(MinimalConfigResource)
      assert name == "minimal_config_resource"
    end
  end

  describe "configured?/1" do
    test "returns true when resolver is configured" do
      assert Info.configured?(FullConfigResource)
      assert Info.configured?(MinimalConfigResource)
    end
  end

  describe "scopes/1" do
    test "returns all scopes" do
      scopes = Info.scopes(FullConfigResource)
      assert length(scopes) == 2

      names = Enum.map(scopes, & &1.name)
      assert :all in names
      assert :own in names
    end

    test "returns empty list when no scopes defined" do
      scopes = Info.scopes(MinimalConfigResource)
      assert scopes == []
    end
  end

  describe "get_scope/2" do
    test "returns scope by name" do
      scope = Info.get_scope(FullConfigResource, :all)
      assert scope.name == :all
      assert scope.filter == true
    end

    test "returns nil for unknown scope" do
      scope = Info.get_scope(FullConfigResource, :nonexistent)
      assert scope == nil
    end
  end

  describe "resolve_scope_filter/3" do
    test "resolves boolean scope" do
      filter = Info.resolve_scope_filter(FullConfigResource, :all, %{})
      assert filter == true
    end

    test "resolves expression scope" do
      filter = Info.resolve_scope_filter(FullConfigResource, :own, %{})
      assert filter != nil
      refute filter == true
      refute filter == false
    end

    test "returns false for unknown scope without legacy resolver" do
      filter = Info.resolve_scope_filter(MinimalConfigResource, :unknown, %{})
      assert filter == false
    end
  end

  describe "scope_resolver/1 (deprecated)" do
    test "returns nil when not configured" do
      resolver = Info.scope_resolver(FullConfigResource)
      assert resolver == nil
    end
  end
end

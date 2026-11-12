# Defined here rather than in test/support: `scope_resolver` emits a deprecation
# warning, which fails `mix compile --warnings-as-errors` in CI.
defmodule AshGrant.Test.LegacyScopeItem.Scopes do
  @moduledoc """
  Legacy `scope_resolver` with clauses for `"always"` and `"mine"` only, as one
  written for RBAC grants would be.
  """
  @behaviour AshGrant.ScopeResolver

  import Ash.Expr

  @impl true
  def resolve("always", _context), do: true
  def resolve("mine", context), do: expr(author_id == ^Map.fetch!(context, :actor).id)
end

defmodule AshGrant.Test.LegacyScopeDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGrant.Test.LegacyScopeItem)
  end
end

defmodule AshGrant.Test.LegacyScopeItem do
  @moduledoc """
  A resource whose scopes all come from a legacy `scope_resolver`. Shares the
  `bulk_test_items` table with `AshGrant.Test.BulkItem`.
  """
  use Ash.Resource,
    domain: AshGrant.Test.LegacyScopeDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("bulk_test_items")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context -> Map.get(actor || %{}, :permissions, []) end)
    scope_resolver(AshGrant.Test.LegacyScopeItem.Scopes)
    resource_name("legacy_scope_item")
    default_policies(true)
    can_perform_actions([:update])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.InstanceScopeLegacyResolverTest do
  @moduledoc """
  An instance grant's scope on a resource with a legacy `scope_resolver` (#207).
  A scope the resolver handles narrows the grant. A scope the resolver raises on
  authorizes nothing, so one stale grant cannot fail every read.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.LegacyScopeItem

  defp item!(author_id) do
    LegacyScopeItem
    |> Ash.Changeset.for_create(:create, %{title: "t", author_id: author_id}, authorize?: false)
    |> Ash.create!()
  end

  # A filter that resolves to `false` makes Ash raise Forbidden instead of
  # returning `[]`; both mean the actor sees nothing.
  defp read_ids(actor) do
    case Ash.read(LegacyScopeItem, actor: actor) do
      {:ok, records} -> records |> Enum.map(& &1.id) |> Enum.sort()
      {:error, %Ash.Error.Forbidden{}} -> []
    end
  end

  test "a scope the resolver handles narrows the instance grant" do
    author_id = Ash.UUID.generate()
    mine = item!(author_id)
    other = item!(Ash.UUID.generate())

    permissions = Enum.map([mine, other], &"legacy_scope_item:#{&1.id}:read:mine")

    assert read_ids(%{id: author_id, permissions: permissions}) == [mine.id]
  end

  test "a scope the resolver raises on authorizes nothing and leaves RBAC grants working" do
    item = item!(Ash.UUID.generate())

    actor = %{
      id: Ash.UUID.generate(),
      permissions: ["legacy_scope_item:*:read:always", "legacy_scope_item:#{item.id}:read:gone"]
    }

    assert read_ids(actor) == [item.id]
    assert read_ids(%{actor | permissions: ["legacy_scope_item:#{item.id}:read:gone"]}) == []
  end

  test "CanPerform is false, not a raise, when the resolver needs context it lacks" do
    author_id = Ash.UUID.generate()
    item = item!(author_id)

    actor = %{
      id: author_id,
      permissions: ["legacy_scope_item:*:read:always", "legacy_scope_item:#{item.id}:update:mine"]
    }

    assert [%{can_update?: false}] =
             LegacyScopeItem |> Ash.Query.load(:can_update?) |> Ash.read!(actor: actor)
  end
end

# Defined here rather than in test/support: the `write:` option emits a
# deprecation warning, which fails `mix compile --warnings-as-errors` in CI.
defmodule AshGrant.Test.WriteOverrideDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGrant.Test.WriteOverrideItem)
  end
end

defmodule AshGrant.Test.WriteOverrideItem do
  @moduledoc """
  A resource whose scopes have a boolean read filter and a different `write:`
  filter. Shares the `bulk_test_items` table with `AshGrant.Test.BulkItem`.
  """
  use Ash.Resource,
    domain: AshGrant.Test.WriteOverrideDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("bulk_test_items")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context -> Map.get(actor || %{}, :permissions, []) end)
    resource_name("write_override_item")
    default_policies(true)

    scope(:everyone, true)
    scope(:read_only, true, write: false)
    scope(:write_only, false, write: true)
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

defmodule AshGrant.InstanceScopeWriteOverrideTest do
  @moduledoc """
  An instance grant on a write action checks the scope's `write:` filter, as an
  RBAC grant with the same scope does, even when the read filter is a boolean.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.WriteOverrideItem

  defp item! do
    WriteOverrideItem
    |> Ash.Changeset.for_create(:create, %{title: "t"}, authorize?: false)
    |> Ash.create!()
  end

  defp update_title(item, permissions) do
    item
    |> Ash.Changeset.for_update(:update, %{title: "changed"})
    |> Ash.update(actor: %{id: Ash.UUID.generate(), permissions: permissions})
  end

  test "write: false denies an instance update, as it denies an RBAC update" do
    item = item!()

    assert {:error, %Ash.Error.Forbidden{}} =
             update_title(item, ["write_override_item:*:update:read_only"])

    assert {:error, %Ash.Error.Forbidden{}} =
             update_title(item, ["write_override_item:#{item.id}:update:read_only"])
  end

  test "write: true allows an instance update, as it allows an RBAC update" do
    item = item!()

    assert {:ok, _} = update_title(item, ["write_override_item:*:update:write_only"])
    assert {:ok, _} = update_title(item, ["write_override_item:#{item.id}:update:write_only"])
  end
end

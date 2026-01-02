defmodule AshGrant.Test.Customer do
  @moduledoc """
  Customer resource for testing geographic/territory and customer relationship scopes.

  Demonstrates:
  - Territory-based filtering
  - Account manager ownership
  - Customer tier filtering (VIP)
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("customers")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil ->
          []

        %{permissions: perms} ->
          perms

        %{role: :admin} ->
          ["customer:*:*:all"]

        %{role: :regional_manager} ->
          [
            "customer:*:read:same_region",
            "customer:*:update:same_region"
          ]

        %{role: :sales_rep} ->
          [
            "customer:*:read:my_accounts",
            "customer:*:update:my_accounts",
            "customer:*:read:assigned_territories"
          ]

        %{role: :vip_manager} ->
          [
            "customer:*:read:vip_only",
            "customer:*:update:vip_only"
          ]

        _ ->
          []
      end
    end)

    resource_name("customer")

    # Geographic scopes
    scope(:all, true)
    scope(:same_region, expr(region_id == ^actor(:region_id)))
    scope(:same_country, expr(country_code == ^actor(:country_code)))
    scope(:assigned_territories, expr(territory_id in ^actor(:territory_ids)))

    # Relationship scopes
    scope(:my_accounts, expr(account_manager_id == ^actor(:id)))
    scope(:vip_only, expr(tier == :vip))
    scope(:standard_only, expr(tier == :standard))
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if(always())
    end

    policy action_type(:read) do
      authorize_if(AshGrant.filter_check())
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(AshGrant.check())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:region_id, :uuid, public?: true)
    attribute(:country_code, :string, public?: true)
    attribute(:territory_id, :uuid, public?: true)
    attribute(:account_manager_id, :uuid, public?: true)

    attribute :tier, :atom do
      constraints(one_of: [:standard, :premium, :vip])
      default(:standard)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name, :region_id, :country_code, :territory_id, :account_manager_id, :tier])
    end

    update :update do
      accept([:name, :region_id, :country_code, :territory_id, :account_manager_id, :tier])
    end
  end
end

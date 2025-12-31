defmodule AshGrant.Test.Journal do
  @moduledoc """
  Journal resource for testing time/period-based scopes.

  Demonstrates:
  - Accounting period filtering
  - Fiscal year filtering
  - Open/closed period access control
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "journals"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["journal:*:*:all"]
        %{role: :controller} -> [
          "journal:*:read:all",
          "journal:*:create:all",
          "journal:*:update:all"
        ]
        %{role: :accountant} -> [
          "journal:*:read:this_fiscal_year",
          "journal:*:create:open_periods",
          "journal:*:update:open_periods"
        ]
        %{role: :auditor} -> [
          "journal:*:read:all"
        ]
        _ -> []
      end
    end

    resource_name "journal"
    owner_field :created_by_id

    # Period-based scopes
    scope :all, true
    scope :current_period, expr(period_id == ^actor(:current_period_id))
    scope :open_periods, expr(period_status == :open)
    scope :closed_periods, expr(period_status == :closed)
    scope :this_fiscal_year, expr(fiscal_year == ^actor(:fiscal_year))
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshGrant.filter_check()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if AshGrant.check()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :description, :string, public?: true
    attribute :amount, :decimal, public?: true
    attribute :period_id, :uuid, public?: true
    attribute :period_status, :atom do
      constraints one_of: [:open, :closed]
      default :open
      public? true
    end
    attribute :fiscal_year, :integer, public?: true
    attribute :created_by_id, :uuid, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:description, :amount, :period_id, :period_status, :fiscal_year, :created_by_id]
    end

    update :update do
      accept [:description, :amount]
    end
  end
end

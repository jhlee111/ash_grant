defmodule AshGrant.Test.Payment do
  @moduledoc """
  Payment resource for testing transaction limit scopes.

  Demonstrates:
  - Amount-based filtering (small, medium, large)
  - Approval limits by role
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "payments"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["payment:*:*:all"]
        %{role: :cfo} -> ["payment:*:*:unlimited"]
        %{role: :finance_manager} -> [
          "payment:*:read:all",
          "payment:*:approve:large_amount"
        ]
        %{role: :accountant} -> [
          "payment:*:read:all",
          "payment:*:approve:medium_amount"
        ]
        %{role: :clerk} -> [
          "payment:*:read:all",
          "payment:*:approve:small_amount"
        ]
        _ -> []
      end
    end

    resource_name "payment"

    # Amount-based scopes
    scope :all, true
    scope :unlimited, true
    scope :small_amount, expr(amount < 1000)
    scope :medium_amount, expr(amount < 10000)
    scope :large_amount, expr(amount < 100000)

    # Status scopes
    scope :pending, expr(status == :pending)
    scope :approved, expr(status == :approved)
    scope :rejected, expr(status == :rejected)
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
    attribute :amount, :decimal, allow_nil?: false, public?: true
    attribute :status, :atom do
      constraints one_of: [:pending, :approved, :rejected]
      default :pending
      public? true
    end
    attribute :approver_id, :uuid, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:description, :amount, :status, :approver_id]
    end

    update :update do
      accept [:description, :status, :approver_id]
    end

    update :approve do
      change set_attribute(:status, :approved)
    end
  end
end

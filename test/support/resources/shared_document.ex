defmodule AshGrant.Test.SharedDocument do
  @moduledoc """
  SharedDocument resource for testing complex ownership and multi-tenant scopes.

  Demonstrates:
  - Created by me + shared with me (OR combination)
  - Multi-tenant filtering
  - Combined tenant + ownership
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "shared_documents"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["shared_document:*:*:all"]
        %{role: :tenant_admin} -> [
          "shared_document:*:read:tenant",
          "shared_document:*:create:tenant",
          "shared_document:*:update:tenant",
          "shared_document:*:delete:tenant_own"
        ]
        %{role: :user} -> [
          "shared_document:*:read:own_or_shared",
          "shared_document:*:create:tenant",
          "shared_document:*:update:created_by_me",
          "shared_document:*:delete:created_by_me"
        ]
        _ -> []
      end
    end

    resource_name "shared_document"

    # Basic ownership scopes
    scope :all, true
    scope :created_by_me, expr(created_by_id == ^actor(:id))
    scope :shared_with_me, expr(id in ^actor(:shared_document_ids))

    # Combined scope (created_by_me OR shared_with_me)
    # This is handled by giving user both permissions which combine with OR

    # Multi-tenant scopes
    scope :tenant, expr(tenant_id == ^actor(:tenant_id))
    scope :tenant_active, [:tenant], expr(status == :active)
    scope :tenant_own, [:tenant], expr(created_by_id == ^actor(:id))

    # Status scopes
    scope :active, expr(status == :active)
    scope :archived, expr(status == :archived)
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
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :created_by_id, :uuid, public?: true
    attribute :tenant_id, :uuid, public?: true
    attribute :status, :atom do
      constraints one_of: [:active, :archived]
      default :active
      public? true
    end
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :created_by_id, :tenant_id, :status]
    end

    update :update do
      accept [:title, :status]
    end
  end
end

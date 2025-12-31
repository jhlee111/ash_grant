defmodule AshGrant.Test.Document do
  @moduledoc """
  Document resource for testing status-based workflow scopes.

  Demonstrates:
  - Status-based filtering (draft, pending_review, approved, archived)
  - Deny rules for approved documents
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "documents"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["document:*:*:all"]
        %{role: :author} -> [
          "document:*:read:all",
          "document:*:create:all",
          "document:*:update:draft",
          "document:*:update:pending_review"
        ]
        %{role: :reviewer} -> [
          "document:*:read:all",
          "document:*:update:pending_review",
          "!document:*:delete:approved"
        ]
        %{role: :reader} -> ["document:*:read:approved"]
        _ -> []
      end
    end

    resource_name "document"
    owner_field :author_id

    # Status-based scopes
    scope :all, true
    scope :draft, expr(status == :draft)
    scope :pending_review, expr(status == :pending_review)
    scope :approved, expr(status == :approved)
    scope :archived, expr(status == :archived)
    scope :editable, expr(status in [:draft, :pending_review])
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
    attribute :content, :string, public?: true
    attribute :status, :atom do
      constraints one_of: [:draft, :pending_review, :approved, :archived]
      default :draft
      public? true
    end
    attribute :author_id, :uuid, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :content, :status, :author_id]
    end

    update :update do
      accept [:title, :content, :status]
    end

    update :submit_for_review do
      change set_attribute(:status, :pending_review)
    end

    update :approve do
      change set_attribute(:status, :approved)
    end
  end
end

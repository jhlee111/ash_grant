defmodule AshGrant.Test.Post do
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "posts"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["post:*:*:all"]
        %{role: :editor} -> ["post:*:read:all", "post:*:update:own", "post:*:create:all"]
        %{role: :viewer} -> ["post:*:read:published"]
        _ -> []
      end
    end

    resource_name "post"

    scope :all, true
    scope :own, expr(author_id == ^actor(:id))
    scope :published, expr(status == :published)
    scope :draft, expr(status == :draft)
    scope :own_draft, [:own], expr(status == :draft)
    scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))

    # Injectable temporal scope - uses context for testability
    scope :today_injectable, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))

    # Injectable parameterized scope - title length threshold
    scope :short_title, expr(fragment("LENGTH(title) <= ?", ^context(:max_title_length)))
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
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :body, :string, public?: true
    attribute :status, :atom do
      constraints one_of: [:draft, :published]
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
      accept [:title, :body, :status, :author_id]
    end

    update :update do
      accept [:title, :body, :status]
    end

    update :publish do
      change set_attribute(:status, :published)
    end
  end
end

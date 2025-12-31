defmodule AshGrant.Test.Report do
  @moduledoc """
  Report resource for testing security classification scopes.

  Demonstrates:
  - Classification-based access (public, internal, confidential, top_secret)
  - Hierarchical security levels
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "reports"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["report:*:*:all"]
        %{role: :executive} -> ["report:*:read:top_secret"]
        %{role: :manager} -> ["report:*:read:confidential"]
        %{role: :employee} -> ["report:*:read:internal"]
        %{role: :public} -> ["report:*:read:public"]
        _ -> []
      end
    end

    resource_name "report"
    owner_field :created_by_id

    # Security classification scopes (hierarchical)
    scope :all, true
    scope :public, expr(classification == :public)
    scope :internal, expr(classification in [:public, :internal])
    scope :confidential, expr(classification in [:public, :internal, :confidential])
    scope :top_secret, true  # Can see all classifications
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
    attribute :classification, :atom do
      constraints one_of: [:public, :internal, :confidential, :top_secret]
      default :public
      public? true
    end
    attribute :created_by_id, :uuid, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :classification, :created_by_id]
    end

    update :update do
      accept [:title, :classification]
    end
  end
end

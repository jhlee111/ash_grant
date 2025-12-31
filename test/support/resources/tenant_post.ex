defmodule AshGrant.Test.TenantPost do
  @moduledoc """
  Test resource for multi-tenancy support testing.

  This resource demonstrates the use of Ash's `^tenant()` template
  in scope expressions for context-based multitenancy.

  ## Key Features

  - Uses `^tenant()` template (not `^actor(:tenant_id)`)
  - Tests context-based multitenancy integration
  - Validates tenant is passed to Ash.Expr.eval

  ## Scopes

  | Scope | Filter |
  |-------|--------|
  | :all | true |
  | :same_tenant | tenant_id == ^tenant() |
  | :own | author_id == ^actor(:id) |
  | :own_in_tenant | [:same_tenant] + author_id == ^actor(:id) |
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "tenant_posts"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :super_admin} -> ["tenant_post:*:*:all"]
        %{role: :tenant_admin} -> [
          "tenant_post:*:read:same_tenant",
          "tenant_post:*:create:same_tenant",
          "tenant_post:*:update:same_tenant",
          "tenant_post:*:destroy:same_tenant"
        ]
        %{role: :tenant_user} -> [
          "tenant_post:*:read:same_tenant",
          "tenant_post:*:create:same_tenant",
          "tenant_post:*:update:own_in_tenant",
          "tenant_post:*:destroy:own_in_tenant"
        ]
        _ -> []
      end
    end

    default_policies true
    resource_name "tenant_post"

    # Key scope using ^tenant() - this is what we're testing!
    scope :all, true
    scope :same_tenant, expr(tenant_id == ^tenant())
    scope :own, expr(author_id == ^actor(:id))
    scope :own_in_tenant, [:same_tenant], expr(author_id == ^actor(:id))
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
    attribute :tenant_id, :uuid, public?: true, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

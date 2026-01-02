defmodule AshGrant.Test.Employee do
  @moduledoc """
  Employee resource for testing organization hierarchy scopes.

  Demonstrates:
  - Organization-based filtering (org_self, org_children, org_subtree)
  - Hierarchical access control
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("employees")
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
          ["employee:*:*:all"]

        %{role: :hr_manager} ->
          ["employee:*:read:all", "employee:*:update:all"]

        %{role: :dept_manager} ->
          [
            "employee:*:read:org_subtree",
            "employee:*:update:org_self"
          ]

        %{role: :team_lead} ->
          ["employee:*:read:org_self"]

        _ ->
          []
      end
    end)

    resource_name("employee")

    # Organization hierarchy scopes
    scope(:all, true)
    scope(:org_self, expr(organization_unit_id == ^actor(:org_unit_id)))
    scope(:org_children, expr(organization_unit_id in ^actor(:child_org_ids)))
    scope(:org_subtree, expr(organization_unit_id in ^actor(:subtree_org_ids)))
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
    attribute(:email, :string, public?: true)
    attribute(:organization_unit_id, :uuid, public?: true)
    attribute(:manager_id, :uuid, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name, :email, :organization_unit_id, :manager_id])
    end

    update :update do
      accept([:name, :email, :organization_unit_id, :manager_id])
    end
  end
end

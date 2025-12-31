defmodule AshGrant.Test.Task do
  @moduledoc """
  Task resource for testing project/team assignment scopes.

  Demonstrates:
  - Project membership filtering
  - Team-based access
  - Personal assignment (assigned to me)
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table "tasks"
    repo AshGrant.TestRepo
  end

  ash_grant do
    resolver fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["task:*:*:all"]
        %{role: :project_manager} -> [
          "task:*:read:my_projects",
          "task:*:create:my_projects",
          "task:*:update:my_projects",
          "task:*:delete:my_projects"
        ]
        %{role: :team_member} -> [
          "task:*:read:my_team",
          "task:*:update:assigned"
        ]
        %{role: :developer} -> [
          "task:*:read:assigned",
          "task:*:update:assigned"
        ]
        _ -> []
      end
    end

    resource_name "task"

    # Project/Team scopes
    scope :all, true
    scope :my_projects, expr(project_id in ^actor(:project_ids))
    scope :my_team, expr(team_id == ^actor(:team_id))
    scope :assigned, expr(assignee_id == ^actor(:id))

    # Status scopes
    scope :open, expr(status == :open)
    scope :in_progress, expr(status == :in_progress)
    scope :completed, expr(status == :completed)
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
    attribute :project_id, :uuid, public?: true
    attribute :team_id, :uuid, public?: true
    attribute :assignee_id, :uuid, public?: true
    attribute :status, :atom do
      constraints one_of: [:open, :in_progress, :completed]
      default :open
      public? true
    end
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :project_id, :team_id, :assignee_id, :status]
    end

    update :update do
      accept [:title, :project_id, :team_id, :assignee_id, :status]
    end
  end
end

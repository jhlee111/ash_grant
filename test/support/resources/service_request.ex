defmodule AshGrant.Test.ServiceRequest do
  @moduledoc """
  Test resource for generic action authorization.

  This resource is specifically designed to test AshGrant's handling of
  Ash generic actions (type: :action), which use ActionInput instead of
  Query or Changeset.

  ## Key Test Scenarios

  - Tenant extraction from action_input (the #76 bug)
  - Generic action authorization with various scopes
  - Mixed CRUD + generic actions on the same resource
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("service_requests")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    # Tenant-aware resolver: uses context.tenant to look up permissions
    resolver(fn actor, context ->
      case actor do
        nil ->
          []

        %{permissions: perms} ->
          perms

        # Simulates a tenant-scoped permission lookup:
        # Returns different permissions depending on the tenant in context
        %{role: :tenant_operator, tenant_id: actor_tenant} ->
          if context[:tenant] != nil and to_string(context[:tenant]) == to_string(actor_tenant) do
            [
              "service_request:*:read:always",
              "service_request:*:create:always",
              "service_request:*:update:own",
              "service_request:*:destroy:own",
              "service_request:*:ping:always",
              "service_request:*:check_status:always"
            ]
          else
            []
          end

        %{role: :admin} ->
          ["service_request:*:*:always"]

        _ ->
          []
      end
    end)

    resource_name("service_request")

    scope(:always, true)
    scope(:own, expr(requester_id == ^actor(:id)))
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

    policy action_type(:action) do
      authorize_if(AshGrant.check())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:requester_id, :uuid, public?: true)
    attribute(:tenant_id, :uuid, public?: true)

    attribute :status, :atom do
      constraints(one_of: [:open, :in_progress, :closed])
      default(:open)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    # Generic actions — use ActionInput, not Query/Changeset
    action :ping, :string do
      run(fn _input, _context -> {:ok, "pong"} end)
    end

    action :check_status, :string do
      argument(:request_id, :uuid, allow_nil?: false)

      run(fn input, _context ->
        {:ok, "status for #{input.arguments.request_id}"}
      end)
    end
  end
end

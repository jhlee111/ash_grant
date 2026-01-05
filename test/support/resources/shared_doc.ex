defmodule AshGrant.Test.SharedDoc do
  @moduledoc """
  SharedDoc resource for testing instance permission read support.

  Demonstrates:
  - Instance-level permissions for specific document access
  - Combined RBAC + instance permissions
  - Deny instance permissions
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("shared_docs")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        nil ->
          []

        %{role: :admin} ->
          ["shareddoc:*:*:all"]

        %{role: :user, id: id, shared_doc_ids: shared_ids} ->
          # RBAC: own documents
          rbac_perms = ["shareddoc:*:read:own", "shareddoc:*:update:own"]

          # Instance permissions for shared documents
          instance_perms =
            Enum.map(shared_ids || [], fn doc_id ->
              "shareddoc:#{doc_id}:read:"
            end)

          # Deny permissions if specified
          deny_perms =
            case actor do
              %{denied_doc_ids: denied_ids} ->
                Enum.map(denied_ids || [], fn doc_id ->
                  "!shareddoc:#{doc_id}:read:"
                end)

              _ ->
                []
            end

          rbac_perms ++ instance_perms ++ deny_perms

        %{role: :guest, shared_doc_ids: shared_ids} ->
          # Guest only has instance permissions, no RBAC
          instance_perms =
            Enum.map(shared_ids || [], fn doc_id ->
              "shareddoc:#{doc_id}:read:"
            end)

          # Deny permissions if specified
          deny_perms =
            case actor do
              %{denied_doc_ids: denied_ids} ->
                Enum.map(denied_ids || [], fn doc_id ->
                  "!shareddoc:#{doc_id}:read:"
                end)

              _ ->
                []
            end

          instance_perms ++ deny_perms

        _ ->
          []
      end
    end)

    resource_name("shareddoc")

    scope(:all, true)
    scope(:own, expr(owner_id == ^actor(:id)))
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
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:owner_id, :string, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:title, :owner_id])
    end

    update :update do
      accept([:title])
    end
  end
end

defmodule AshGrant.Test.DomainOverridePost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.GrantDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    # Own resolver overrides domain's
    resolver(fn actor, _context ->
      case actor do
        nil -> []
        %{permissions: perms} -> perms
        %{role: :admin} -> ["domain_override_post:*:*:always"]
        _ -> []
      end
    end)

    default_policies(true)

    # Own :own scope overrides domain's :own
    scope(:own, expr(creator_id == ^actor(:id)))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:creator_id, :uuid, public?: true)
    attribute(:author_id, :uuid, public?: true)

    attribute :status, :atom do
      constraints(one_of: [:draft, :published])
      default(:draft)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:title, :creator_id, :author_id, :status])
    end

    update :update do
      accept([:title, :status])
    end
  end
end

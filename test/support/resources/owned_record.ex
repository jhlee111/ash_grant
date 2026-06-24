defmodule AshGrant.Test.OwnedRecord do
  @moduledoc """
  Test resource for per-record field visibility (issue #117 phase ②).

  Has BOTH field groups and a relational `:own` scope, so per-record field
  visibility (e.g. "public on all rows, secret only on own rows") can be
  exercised — the pattern the action-wide model cannot express.

  Field groups: `:public [:title] ⊂ :sensitive [:secret]`.
  Scopes: `:always` (true) and `:own` (`owner_id == ^actor(:id)`).
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    default_policies(true)
    default_field_policies(true)
    resource_name("ownedrecord")

    scope(:always, true)
    scope(:own, expr(owner_id == ^actor(:id)))

    field_group(:public, [:title])
    field_group(:sensitive, [:secret], inherits: [:public])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:secret, :string, public?: true)
    attribute(:owner_id, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

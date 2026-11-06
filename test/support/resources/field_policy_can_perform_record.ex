defmodule AshGrant.Test.FieldPolicyCanPerformRecord do
  @moduledoc """
  Test resource combining `default_field_policies(true)` with
  `can_perform_actions`, so the generated CanPerform calculations must be
  covered by the generated field policies.
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
    resource_name("fieldpolicycanperformrecord")

    scope(:always, true)
    scope(:own, expr(owner_id == ^actor(:id)))

    field_group(:public, [:title])
    field_group(:sensitive, [:secret], inherits: [:public])

    can_perform_actions([:update, :destroy])
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

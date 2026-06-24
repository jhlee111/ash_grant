defmodule AshGrant.Test.StrictFieldGroupRecord do
  @moduledoc """
  Test resource mirroring `SensitiveRecord` but with
  `field_group_permissions :strict` (issue #117, phase ①).

  Used to verify end-to-end that a deny rule carrying a field_group
  (`!record:*:read:always:sensitive`) raises
  `AshGrant.PermissionValidation.InvalidPermissionError` through the checks,
  rather than silently over-denying.
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
    resource_name("strictfieldgrouprecord")
    field_group_permissions(:strict)

    scope(:always, true)

    field_group(:public, [:name, :department])
    field_group(:sensitive, [:phone, :address], inherits: [:public])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:department, :string, public?: true)
    attribute(:phone, :string, public?: true)
    attribute(:address, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

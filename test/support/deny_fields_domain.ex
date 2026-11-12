defmodule AshGrant.Test.DenyFieldsDomain do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshGrant.Domain],
    validate_config_inclusion?: false

  ash_grant do
    deny_fields_by_default(true)
  end

  resources do
    resource(AshGrant.Test.DenyFieldsDomainRecord)
    resource(AshGrant.Test.DenyFieldsOptOutRecord)
  end
end

defmodule AshGrant.Test.DenyFieldsDomainRecord do
  @moduledoc """
  Inherits `deny_fields_by_default true` from `AshGrant.Test.DenyFieldsDomain`.
  `name` is in the `:public` group; `notes` is in no group.
  """
  use Ash.Resource,
    domain: AshGrant.Test.DenyFieldsDomain,
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
    resource_name("denyfieldsdomainrecord")

    scope(:always, true)

    field_group(:public, [:name])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:notes, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.DenyFieldsOptOutRecord do
  @moduledoc """
  Sets `deny_fields_by_default false`, overriding `AshGrant.Test.DenyFieldsDomain`.
  `name` is in the `:public` group; `notes` is in no group.
  """
  use Ash.Resource,
    domain: AshGrant.Test.DenyFieldsDomain,
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
    deny_fields_by_default(false)
    resource_name("denyfieldsoptoutrecord")

    scope(:always, true)

    field_group(:public, [:name])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:notes, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

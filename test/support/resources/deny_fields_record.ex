defmodule AshGrant.Test.DenyFieldsRecord do
  @moduledoc """
  Test resource for `deny_fields_by_default true` set on the resource.

  | Group | Own Fields | Inherits From | Masking |
  |-------|-----------|---------------|---------|
  | :public | name, department | — | none |
  | :sensitive | phone | :public | phone |
  | :confidential | salary | :sensitive | none |

  `notes` is in no group.
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
    deny_fields_by_default(true)
    resource_name("denyfieldsrecord")

    scope(:always, true)

    field_group(:public, [:name, :department])

    field_group(:sensitive, [:phone],
      inherits: [:public],
      mask: [:phone],
      mask_with: &AshGrant.Test.MaskHelpers.mask_string/2
    )

    field_group(:confidential, [:salary], inherits: [:sensitive])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:department, :string, public?: true)
    attribute(:phone, :string, public?: true)
    attribute(:salary, :integer, public?: true)
    attribute(:notes, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.DenyFieldsExceptRecord do
  @moduledoc """
  Test resource for `deny_fields_by_default true` with an `:all, except:` group.

  | Group | Definition |
  |-------|-----------|
  | :public | `:all, except: [:salary]` |
  | :full | `[:salary]`, inherits :public |
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
    deny_fields_by_default(true)
    resource_name("denyfieldsexceptrecord")

    scope(:always, true)

    field_group(:public, :all, except: [:salary])
    field_group(:full, [:salary], inherits: [:public])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:salary, :integer, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.DenyFieldsDisjointRecord do
  @moduledoc """
  Test resource for `deny_fields_by_default true` with two disjoint groups:
  `:a` shows `name`, `:b` shows `email`. `notes` is in no group.
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
    deny_fields_by_default(true)
    resource_name("denyfieldsdisjointrecord")

    scope(:always, true)

    field_group(:a, [:name])
    field_group(:b, [:email])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:notes, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.DenyFieldsAppConfigRecord do
  @moduledoc """
  Sets `deny_fields_by_default` neither on itself nor on its domain, so only
  `config :ash_grant, :deny_fields_by_default` turns it on. `name` is in the
  `:public` group; `notes` is in no group.
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
    resource_name("denyfieldsappconfigrecord")

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

defmodule AshGrant.Test.ComputedFieldRecord do
  @moduledoc """
  Test resource whose `:sensitive` field group holds a calculation and an
  aggregate next to a plain attribute.

  `AshGrant.Transformers.AddFieldPolicies` accepts public calculations and
  aggregates as field-policy targets, so a generated field policy can be the only
  thing standing between an actor and a computed value. Ash nils a forbidden
  field when a filter references it; before Ash 3.33.4 that applied to attributes
  only, leaving calculations and aggregates usable as a filter oracle
  (CVE-2026-86338).

  Field groups: `:public [:title] ⊂ :sensitive [:secret, :secret_calc, :note_count]`.
  Scopes: `:always` (true) and `:own` (`owner_id == ^actor(:id)`).
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ets do
    private?(true)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    default_policies(true)
    default_field_policies(true)
    resource_name("computedfieldrecord")

    scope(:always, true)
    scope(:own, expr(owner_id == ^actor(:id)))

    field_group(:public, [:title])
    field_group(:sensitive, [:secret, :secret_calc, :note_count], inherits: [:public])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:secret, :string, public?: true)
    attribute(:owner_id, :string, public?: true)
  end

  calculations do
    # The same value as `:secret`, exposed as a calculation.
    calculate(:secret_calc, :string, expr(secret), public?: true)
  end

  aggregates do
    count(:note_count, :notes, public?: true)
  end

  relationships do
    has_many :notes, AshGrant.Test.ComputedFieldNote do
      destination_attribute(:record_id)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.ComputedFieldNote do
  @moduledoc """
  Child of `AshGrant.Test.ComputedFieldRecord`; exists only so the parent has
  something to count in its `:note_count` aggregate. Not authorized.
  """
  use Ash.Resource,
    domain: AshGrant.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
  end

  relationships do
    belongs_to :record, AshGrant.Test.ComputedFieldRecord do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*])
  end
end

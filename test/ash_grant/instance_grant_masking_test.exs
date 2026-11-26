defmodule AshGrant.InstanceGrantMaskingTest do
  @moduledoc """
  Field masking from instance grants, with `deny_fields_by_default` off. An
  instance grant's field group applies on its record, and a scoped instance
  grant unmasks a field only on a record where its scope holds.
  """
  use ExUnit.Case, async: true

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Record do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.InstanceGrantMaskingTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ash_grant do
      resolver(fn actor, _ -> actor.permissions end)
      default_policies(true)
      default_field_policies(true)
      resource_name("igmrecord")

      scope(:always, true)
      scope(:own, expr(owner_id == ^actor(:id)))

      field_group(:public, [:name])

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
      attribute(:phone, :string, public?: true)
      attribute(:salary, :integer, public?: true)
      attribute(:owner_id, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defp create!(owner_id) do
    Record
    |> Ash.Changeset.for_create(:create, %{
      name: "Ada",
      phone: "555",
      salary: 100,
      owner_id: owner_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp read(record, permissions) do
    Record
    |> Ash.read!(actor: %{id: "me", permissions: permissions})
    |> Enum.find(&(&1.id == record.id))
  end

  test "an instance grant for a masked group masks the field on its record" do
    record = create!("me")
    result = read(record, ["igmrecord:#{record.id}:read::sensitive"])

    assert result.name == "Ada"
    assert result.phone == "***"
    assert %Ash.ForbiddenField{} = result.salary
  end

  test "a scoped instance grant does not unmask a field where its scope fails" do
    record = create!("someone else")

    result =
      read(record, [
        "igmrecord:*:read:always:sensitive",
        "igmrecord:#{record.id}:read:own:confidential"
      ])

    assert result.phone == "***"
    assert %Ash.ForbiddenField{} = result.salary
  end

  test "a scoped instance grant unmasks a field where its scope holds" do
    record = create!("me")

    result =
      read(record, [
        "igmrecord:*:read:always:sensitive",
        "igmrecord:#{record.id}:read:own:confidential"
      ])

    assert result.phone == "555"
    assert result.salary == 100
  end

  test "an instance grant spelled in uppercase applies its group on the record, as the field policy does" do
    record = create!("me")

    result =
      read(record, [
        "igmrecord:*:read:always:sensitive",
        "igmrecord:#{String.upcase(record.id)}:read::confidential"
      ])

    assert result.salary == 100
    assert result.phone == "555"
  end
end

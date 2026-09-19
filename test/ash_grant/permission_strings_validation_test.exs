defmodule AshGrant.PermissionStringsValidationTest do
  @moduledoc """
  `AshGrant.Validations.PermissionStrings` (issue #162): the Ash validation for
  the attribute where an application stores grants.
  """
  use ExUnit.Case, async: true

  alias AshGrant.Validations.PermissionStrings

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Role do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.PermissionStringsValidationTest.Domain,
      validate_domain_inclusion?: false

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:permissions, {:array, :string}, public?: true, default: [])
    end

    actions do
      defaults([:read, create: :*, update: :*])

      update :strict_update do
        accept([:permissions])

        validate(
          {PermissionStrings,
           attribute: :permissions, resources: [AshGrant.Test.Post], reject: :warnings}
        )
      end
    end

    validations do
      validate({PermissionStrings, attribute: :permissions, resources: [AshGrant.Test.Post]},
        on: [:create, :update]
      )
    end
  end

  defp create(permissions),
    do: Ash.Changeset.for_create(Role, :create, %{name: "editor", permissions: permissions})

  defp update(action \\ :update, params) do
    role = struct(Role, id: Ash.UUID.generate(), name: "editor", permissions: ["post:*:read:owm"])
    Ash.Changeset.for_update(role, action, params)
  end

  test "a clean list passes through" do
    changeset = create(["post:*:read:always", "post:*:update:own", "!post:*:destroy:always"])

    assert changeset.valid?
    assert changeset.errors == []
  end

  test "an empty list and nil pass" do
    assert create([]).valid?
    assert create(nil).valid?
  end

  test "adds one field error per bad string, naming the string" do
    changeset = create(["post:*:read:always", "post:*:read:owm", "pots:*:read:always"])

    refute changeset.valid?
    # Ash prepends errors, so the order is not the input order.
    assert [scope_error, resource_error] = Enum.sort_by(changeset.errors, & &1.value)

    for error <- [scope_error, resource_error] do
      assert %Ash.Error.Changes.InvalidAttribute{field: :permissions} = error
    end

    assert scope_error.value == "post:*:read:owm"
    assert Exception.message(scope_error) =~ "post:*:read:owm"
    assert Exception.message(scope_error) =~ "Scope `owm` is not declared"
    assert scope_error.vars[:codes] == [:undeclared_scope]

    assert resource_error.value == "pots:*:read:always"
    assert resource_error.vars[:codes] == [:unknown_resource]
  end

  test "a string with a warning and an error still yields a single error" do
    changeset = create(["post:*:delete*:always"])

    assert [error] = changeset.errors
    # Only the error is rejected; the deprecated-spelling warning is not.
    assert error.vars[:codes] == [:unknown_action_type]
  end

  test "warnings alone pass by default" do
    assert create(["post:*:read*:always"]).valid?
  end

  test "reject: :warnings rejects them" do
    changeset = update(:strict_update, %{permissions: ["post:*:read*:always"]})

    assert [error] = changeset.errors
    assert error.vars[:codes] == [:deprecated_type_wildcard]
  end

  test "strings already stored are not re-checked when the attribute is untouched" do
    # The record holds a string that no longer checks out; renaming the role
    # must not be blocked by it.
    assert update(%{name: "author"}).valid?
  end

  test "init/1 rejects bad options" do
    assert {:error, _} = PermissionStrings.init([])
    assert {:error, _} = PermissionStrings.init(attribute: "permissions")
    assert {:error, _} = PermissionStrings.init(attribute: :permissions, reject: :everything)
    assert {:ok, _} = PermissionStrings.init(attribute: :permissions)
  end
end

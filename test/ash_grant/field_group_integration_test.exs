defmodule AshGrant.FieldGroupIntegrationTest do
  @moduledoc """
  End-to-end integration tests for field group access control.

  Tests the full flow: create records with authorize?: false, then read
  with different field_group permissions and verify which fields are
  visible vs replaced with %Ash.ForbiddenField{}.

  Uses the SensitiveRecord ETS resource which has:
  - field_group :public       — [:name, :department, :position]
  - field_group :sensitive    — inherits :public, adds [:phone, :address]
  - field_group :confidential — inherits :sensitive, adds [:salary, :email]
  - default_policies true, default_field_policies true
  - scope :always, true
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.SensitiveRecord

  # Helper to create a record without authorization
  defp create_record!(attrs \\ %{}) do
    defaults = %{
      name: "John Doe",
      department: "Engineering",
      position: "Senior Developer",
      email: "john@example.com",
      phone: "010-1234-5678",
      address: "123 Main St",
      salary: 80_000
    }

    merged = Map.merge(defaults, attrs)

    SensitiveRecord
    |> Ash.Changeset.for_create(:create, merged, authorize?: false)
    |> Ash.create!()
  end

  defp read_records(actor) do
    SensitiveRecord |> Ash.read!(actor: actor)
  end

  # Find a record by ID from the read results.
  # Since ETS is shared across tests, we filter by known ID.
  defp find_record(results, id) do
    Enum.find(results, fn r -> r.id == id end)
  end

  defp forbidden_field?(value) do
    match?(%Ash.ForbiddenField{}, value)
  end

  describe "field group access control (Mode B — auto-generated)" do
    setup do
      record = create_record!()
      %{record: record}
    end

    test "actor with :public field_group sees only public fields", %{record: record} do
      actor = %{permissions: ["sensitiverecord:*:read:always:public"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found in results"

      # Public fields visible
      assert result.name == "John Doe"
      assert result.department == "Engineering"
      assert result.position == "Senior Developer"

      # Sensitive fields forbidden
      assert forbidden_field?(result.phone)
      assert forbidden_field?(result.address)

      # Confidential fields forbidden
      assert forbidden_field?(result.salary)
      assert forbidden_field?(result.email)
    end

    test "actor with :sensitive field_group sees public + sensitive fields", %{record: record} do
      actor = %{permissions: ["sensitiverecord:*:read:always:sensitive"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found in results"

      # Public fields visible (inherited by :sensitive)
      assert result.name == "John Doe"
      assert result.department == "Engineering"
      assert result.position == "Senior Developer"

      # Sensitive fields visible (own fields of :sensitive)
      assert result.phone == "010-1234-5678"
      assert result.address == "123 Main St"

      # Confidential fields forbidden
      assert forbidden_field?(result.salary)
      assert forbidden_field?(result.email)
    end

    test "actor with :confidential field_group sees all fields", %{record: record} do
      actor = %{permissions: ["sensitiverecord:*:read:always:confidential"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found in results"

      # All fields visible (confidential inherits sensitive which inherits public)
      assert result.name == "John Doe"
      assert result.department == "Engineering"
      assert result.position == "Senior Developer"
      assert result.phone == "010-1234-5678"
      assert result.address == "123 Main St"
      assert result.salary == 80_000
      assert result.email == "john@example.com"
    end

    test "actor with no field_group (4-part permission) sees all fields", %{record: record} do
      actor = %{permissions: ["sensitiverecord:*:read:always"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found in results"

      # No field restriction — all fields visible
      assert result.name == "John Doe"
      assert result.department == "Engineering"
      assert result.position == "Senior Developer"
      assert result.phone == "010-1234-5678"
      assert result.address == "123 Main St"
      assert result.salary == 80_000
      assert result.email == "john@example.com"
    end

    test "actor with no permissions raises Forbidden", %{record: _record} do
      actor = %{permissions: []}

      assert_raise Ash.Error.Forbidden, fn ->
        read_records(actor)
      end
    end

    test "nil actor raises Forbidden", %{record: _record} do
      assert_raise Ash.Error.Forbidden, fn ->
        SensitiveRecord |> Ash.read!(actor: nil)
      end
    end

    test "multiple field_groups union — sees fields from both groups", %{record: record} do
      # Actor has both :public and :sensitive field_group permissions
      actor = %{
        permissions: [
          "sensitiverecord:*:read:always:public",
          "sensitiverecord:*:read:always:sensitive"
        ]
      }

      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found in results"

      # Should see union: public + sensitive fields
      assert result.name == "John Doe"
      assert result.department == "Engineering"
      assert result.position == "Senior Developer"
      assert result.phone == "010-1234-5678"
      assert result.address == "123 Main St"

      # Confidential fields still forbidden
      assert forbidden_field?(result.salary)
      assert forbidden_field?(result.email)
    end

    test "field_group hierarchy: :confidential subsumes :public", %{record: record} do
      # An actor with :confidential should see everything a :public actor sees plus more
      public_actor = %{permissions: ["sensitiverecord:*:read:always:public"]}
      confidential_actor = %{permissions: ["sensitiverecord:*:read:always:confidential"]}

      pub_results = read_records(public_actor)
      conf_results = read_records(confidential_actor)

      pub_result = find_record(pub_results, record.id)
      conf_result = find_record(conf_results, record.id)

      assert pub_result != nil
      assert conf_result != nil

      # Public fields visible for both
      assert pub_result.name == "John Doe"
      assert conf_result.name == "John Doe"

      # Public actor cannot see confidential fields
      assert forbidden_field?(pub_result.salary)
      assert forbidden_field?(pub_result.email)

      # Confidential actor can see all fields
      assert conf_result.salary == 80_000
      assert conf_result.email == "john@example.com"
    end

    test "multiple records — field restrictions apply consistently", %{record: record} do
      record2 =
        create_record!(%{
          name: "Jane Smith",
          department: "Finance",
          position: "Analyst",
          email: "jane@example.com",
          phone: "010-9876-5432",
          address: "456 Oak Ave",
          salary: 75_000
        })

      actor = %{permissions: ["sensitiverecord:*:read:always:public"]}
      results = read_records(actor)

      r1 = find_record(results, record.id)
      r2 = find_record(results, record2.id)

      assert r1 != nil
      assert r2 != nil

      # Both records should have public fields visible
      assert r1.name == "John Doe"
      assert r2.name == "Jane Smith"

      # Both should have confidential fields forbidden
      assert forbidden_field?(r1.salary)
      assert forbidden_field?(r2.salary)
      assert forbidden_field?(r1.email)
      assert forbidden_field?(r2.email)
    end
  end
end

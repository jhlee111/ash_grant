defmodule AshGrant.MaskingIntegrationTest do
  @moduledoc """
  Integration tests for field masking.

  Tests the full flow: create records, read with different field_group
  permissions, and verify masking behavior.

  Uses the MaskedRecord ETS resource which has:
  - field_group :public       — [:name, :department] (no masking)
  - field_group :sensitive    — inherits :public, adds [:phone, :address] (masks phone, address)
  - field_group :confidential — inherits :sensitive, adds [:salary, :email] (no masking)
  """
  use ExUnit.Case, async: true

  alias AshGrant.Test.MaskedRecord

  defp create_record!(attrs \\ %{}) do
    defaults = %{
      name: "John Doe",
      department: "Engineering",
      phone: "010-1234-5678",
      address: "123 Main St",
      salary: 80_000,
      email: "john@example.com"
    }

    merged = Map.merge(defaults, attrs)

    MaskedRecord
    |> Ash.Changeset.for_create(:create, merged, authorize?: false)
    |> Ash.create!()
  end

  defp read_records(actor) do
    MaskedRecord |> Ash.read!(actor: actor)
  end

  defp find_record(results, id) do
    Enum.find(results, fn r -> r.id == id end)
  end

  defp forbidden_field?(value) do
    match?(%Ash.ForbiddenField{}, value)
  end

  describe "masking with :sensitive field_group" do
    setup do
      record = create_record!()
      %{record: record}
    end

    test "actor with :sensitive sees phone and address masked", %{record: record} do
      actor = %{permissions: ["maskedrecord:*:read:always:sensitive"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found"

      # Public fields visible (unmasked — :public group has no masking)
      assert result.name == "John Doe"
      assert result.department == "Engineering"

      # Sensitive fields visible but MASKED
      # "010-1234-5678" (13 chars) → "*************"
      assert result.phone == "*************"
      # "123 Main St" (11 chars) → "***********"
      assert result.address == "***********"

      # Confidential fields forbidden (not in :sensitive group)
      assert forbidden_field?(result.salary)
      assert forbidden_field?(result.email)
    end

    test "actor with :confidential sees phone and address unmasked", %{record: record} do
      # :confidential inherits :sensitive, but masking doesn't inherit
      # So confidential actor sees original values
      actor = %{permissions: ["maskedrecord:*:read:always:confidential"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found"

      # All fields visible and unmasked
      assert result.name == "John Doe"
      assert result.department == "Engineering"
      assert result.phone == "010-1234-5678"
      assert result.address == "123 Main St"
      assert result.salary == 80_000
      assert result.email == "john@example.com"
    end

    test "actor with :public cannot see sensitive fields at all", %{record: record} do
      actor = %{permissions: ["maskedrecord:*:read:always:public"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found"

      # Public fields visible
      assert result.name == "John Doe"
      assert result.department == "Engineering"

      # Sensitive fields forbidden (not visible, not masked)
      assert forbidden_field?(result.phone)
      assert forbidden_field?(result.address)

      # Confidential fields forbidden
      assert forbidden_field?(result.salary)
      assert forbidden_field?(result.email)
    end

    test "actor with 4-part permission (no field_group) sees all unmasked", %{record: record} do
      # No field_group means unrestricted field access — no masking applies
      actor = %{permissions: ["maskedrecord:*:read:always"]}
      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found"

      assert result.name == "John Doe"
      assert result.phone == "010-1234-5678"
      assert result.address == "123 Main St"
      assert result.salary == 80_000
      assert result.email == "john@example.com"
    end
  end

  describe "allow-wins masking semantics" do
    setup do
      record = create_record!()
      %{record: record}
    end

    test "actor with both :sensitive and :confidential sees unmasked (allow-wins)", %{
      record: record
    } do
      # :confidential provides unmasked access to phone/address
      # :sensitive masks phone/address
      # Allow-wins: unmasked wins
      actor = %{
        permissions: [
          "maskedrecord:*:read:always:sensitive",
          "maskedrecord:*:read:always:confidential"
        ]
      }

      results = read_records(actor)
      result = find_record(results, record.id)

      assert result != nil, "record not found"

      # Phone and address should be unmasked (allow-wins)
      assert result.phone == "010-1234-5678"
      assert result.address == "123 Main St"
    end
  end

  describe "masking with multiple records" do
    test "masking applies consistently across multiple records" do
      r1 = create_record!(%{name: "Alice", phone: "010-1111-1111", address: "111 First Ave"})
      r2 = create_record!(%{name: "Bob", phone: "010-2222-2222", address: "222 Second Ave"})

      actor = %{permissions: ["maskedrecord:*:read:always:sensitive"]}
      results = read_records(actor)

      result1 = find_record(results, r1.id)
      result2 = find_record(results, r2.id)

      assert result1 != nil
      assert result2 != nil

      # Names visible (public)
      assert result1.name == "Alice"
      assert result2.name == "Bob"

      # Phones masked (sensitive with masking)
      # "010-1111-1111" (13 chars) → "*************"
      assert result1.phone == "*************"
      # "010-2222-2222" (13 chars) → "*************"
      assert result2.phone == "*************"

      # Addresses masked
      # "111 First Ave" (13 chars) → "*************"
      assert result1.address == "*************"
      # "222 Second Ave" (14 chars) → "**************"
      assert result2.address == "**************"
    end
  end
end

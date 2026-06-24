defmodule AshGrant.PermissionValidationTest do
  @moduledoc """
  Unit tests for AshGrant.PermissionValidation (issue #117, phase ①).

  A permission that is BOTH a deny (`!`) AND carries a field_group (5th part) is
  invalid: deny + field_group currently over-denies the whole action (fail-closed).
  The validator only *signals* this per the configured mode — it never changes the
  authorization outcome.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshGrant.PermissionValidation
  alias AshGrant.PermissionValidation.InvalidPermissionError

  @deny_fg ["employee:*:read:always", "!employee:*:read:always:sensitive"]

  describe "validate/3 — deny + field_group detection" do
    test ":strict raises InvalidPermissionError naming the offending permission" do
      err =
        assert_raise InvalidPermissionError, fn ->
          PermissionValidation.validate(@deny_fg, :strict)
        end

      assert err.message =~ "field_group"
      assert err.message =~ "!employee:*:read:always:sensitive"
    end

    test ":warn logs a warning but does not raise and returns :ok" do
      log =
        capture_log(fn ->
          assert PermissionValidation.validate(@deny_fg, :warn) == :ok
        end)

      assert log =~ "field_group"
      assert log =~ "!employee:*:read:always:sensitive"
    end

    test ":off does nothing — no raise, no log, returns :ok" do
      log =
        capture_log(fn ->
          assert PermissionValidation.validate(@deny_fg, :off) == :ok
        end)

      refute log =~ "field_group"
    end

    test "accepts raw permission strings and %Permission{} structs alike" do
      structs = Enum.map(@deny_fg, &AshGrant.Permission.parse!/1)

      assert_raise InvalidPermissionError, fn ->
        PermissionValidation.validate(structs, :strict)
      end
    end

    test "includes the resource in the message when given" do
      err =
        assert_raise InvalidPermissionError, fn ->
          PermissionValidation.validate(@deny_fg, :strict, resource: MyApp.Employee)
        end

      assert err.message =~ "MyApp.Employee"
    end
  end

  describe "validate/3 — valid permissions pass in every mode" do
    # Each of these must NOT signal: they are either allows carrying a field_group
    # (legitimate), plain denies with no field_group, or a 5-part deny whose
    # field_group is empty (parses to nil — not a field-group deny).
    @valid [
      ["employee:*:read:always:sensitive"],
      ["employee:*:read:own:sensitive"],
      ["employee:*:read:always", "!employee:*:read:always"],
      ["!employee:*:read:always:"]
    ]

    test ":strict does not raise for any valid set" do
      for perms <- @valid do
        assert PermissionValidation.validate(perms, :strict) == :ok,
               "expected #{inspect(perms)} to be valid"
      end
    end

    test ":warn does not log for any valid set" do
      log =
        capture_log(fn ->
          for perms <- @valid, do: PermissionValidation.validate(perms, :warn)
        end)

      refute log =~ "field_group"
    end
  end

  describe "validate/3 — :warn dedups within a process" do
    test "logs at most once for repeated identical offenders in the same process" do
      log =
        capture_log(fn ->
          PermissionValidation.validate(@deny_fg, :warn)
          PermissionValidation.validate(@deny_fg, :warn)
          PermissionValidation.validate(@deny_fg, :warn)
        end)

      occurrences = length(Regex.scan(~r/!employee:\*:read:always:sensitive/, log))
      assert occurrences == 1, "expected exactly one warning, got #{occurrences}"
    end

    test "warns separately for the same offenders on different resources" do
      log =
        capture_log(fn ->
          PermissionValidation.validate(@deny_fg, :warn, resource: MyApp.A)
          PermissionValidation.validate(@deny_fg, :warn, resource: MyApp.B)
        end)

      occurrences = length(Regex.scan(~r/!employee:\*:read:always:sensitive/, log))
      assert occurrences == 2, "expected one warning per resource, got #{occurrences}"
    end
  end
end

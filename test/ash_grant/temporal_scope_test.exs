defmodule AshGrant.TemporalScopeTest do
  @moduledoc """
  Tests for temporal (time-based) scope definitions.

  These tests verify that scope DSL can handle date/time based filtering
  such as "records created today" or "records from this week".
  """
  use ExUnit.Case, async: true

  alias AshGrant.Info

  # Test resource with temporal scopes
  defmodule Ledger do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver fn _actor, _context -> [] end

      # Boolean scope - no filtering
      scope :all, true

      # Temporal scope - records from today
      # Using fragment for database-level date comparison
      scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))

      # Temporal scope - records from this week
      scope :this_week, expr(
        fragment("inserted_at >= DATE_TRUNC('week', CURRENT_DATE)")
      )

      # Temporal scope - records from this month
      scope :this_month, expr(
        fragment("DATE_TRUNC('month', inserted_at) = DATE_TRUNC('month', CURRENT_DATE)")
      )

      # Recent records (last 7 days) - alternative approach
      scope :recent, expr(
        fragment("inserted_at >= CURRENT_DATE - INTERVAL '7 days'")
      )
    end

    attributes do
      uuid_primary_key :id
      attribute :description, :string, public?: true
      attribute :amount, :decimal
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end
  end

  # Test resource with combined temporal + ownership scopes
  defmodule Transaction do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver fn _actor, _context -> [] end

      scope :all, true

      # Only user's own transactions
      scope :own, expr(user_id == ^actor(:id))

      # Today's transactions
      scope :today, expr(fragment("DATE(inserted_at) = CURRENT_DATE"))

      # Combined: own + today (using inheritance)
      scope :own_today, [:own], expr(fragment("DATE(inserted_at) = CURRENT_DATE"))

      # Own transactions from this week
      scope :own_this_week, [:own], expr(
        fragment("inserted_at >= DATE_TRUNC('week', CURRENT_DATE)")
      )
    end

    attributes do
      uuid_primary_key :id
      attribute :amount, :decimal
      attribute :user_id, :uuid
      create_timestamp :inserted_at
    end
  end

  describe "temporal scope definition" do
    test "defines temporal scopes with fragment" do
      scopes = Info.scopes(Ledger)
      scope_names = Enum.map(scopes, & &1.name)

      assert :today in scope_names
      assert :this_week in scope_names
      assert :this_month in scope_names
      assert :recent in scope_names
    end

    test "today scope has fragment filter" do
      scope = Info.get_scope(Ledger, :today)

      assert scope != nil
      assert scope.name == :today
      # Filter should be an expression (not boolean true)
      refute scope.filter == true
    end

    test "this_week scope has fragment filter" do
      scope = Info.get_scope(Ledger, :this_week)

      assert scope != nil
      assert scope.name == :this_week
      refute scope.filter == true
    end
  end

  describe "combined temporal + ownership scopes" do
    test "defines combined scopes with inheritance" do
      scopes = Info.scopes(Transaction)
      scope_names = Enum.map(scopes, & &1.name)

      assert :own in scope_names
      assert :today in scope_names
      assert :own_today in scope_names
      assert :own_this_week in scope_names
    end

    test "own_today inherits from own" do
      scope = Info.get_scope(Transaction, :own_today)

      assert scope.inherits == [:own]
      refute scope.filter == true
    end

    test "own_this_week inherits from own" do
      scope = Info.get_scope(Transaction, :own_this_week)

      assert scope.inherits == [:own]
    end

    test "resolve_scope_filter combines inherited scope" do
      filter = Info.resolve_scope_filter(Transaction, :own_today, %{})

      # Should return a filter (not true or false)
      assert filter != nil
      assert filter != true
      assert filter != false
    end
  end

  describe "scope resolution" do
    test "resolves :all scope to true" do
      filter = Info.resolve_scope_filter(Ledger, :all, %{})
      assert filter == true
    end

    test "resolves temporal scope to expression" do
      filter = Info.resolve_scope_filter(Ledger, :today, %{})

      # Should be an expression, not a boolean
      refute is_boolean(filter)
    end

    test "resolves unknown scope to false" do
      filter = Info.resolve_scope_filter(Ledger, :nonexistent, %{})
      assert filter == false
    end
  end

  describe "permission string integration" do
    test "temporal scopes work with permission format" do
      # These would be valid permission strings
      permissions = [
        "ledger:*:read:all",
        "ledger:*:update:today",
        "ledger:*:delete:today",
        "transaction:*:read:own",
        "transaction:*:update:own_today"
      ]

      # Verify evaluator can parse and evaluate these
      alias AshGrant.Evaluator

      assert Evaluator.has_access?(permissions, "ledger", "read")
      assert Evaluator.has_access?(permissions, "ledger", "update")
      assert Evaluator.has_access?(permissions, "transaction", "read")
      assert Evaluator.has_access?(permissions, "transaction", "update")

      # Check scopes are correctly extracted
      assert Evaluator.get_scope(permissions, "ledger", "read") == "all"
      assert Evaluator.get_scope(permissions, "ledger", "update") == "today"
      assert Evaluator.get_scope(permissions, "transaction", "read") == "own"
      assert Evaluator.get_scope(permissions, "transaction", "update") == "own_today"
    end
  end
end

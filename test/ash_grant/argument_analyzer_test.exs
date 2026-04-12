defmodule AshGrant.ArgumentAnalyzerTest do
  @moduledoc """
  Unit tests for `AshGrant.ArgumentAnalyzer` — the compile-time AST walker that
  extracts `^arg(...)` references from scope expressions.

  Tests use raw Ash expression AST fragments (not full DSL wiring) to isolate
  the walker from the rest of the extension.
  """
  use ExUnit.Case, async: true

  require Ash.Expr
  import Ash.Expr

  alias AshGrant.ArgumentAnalyzer

  describe "referenced_args/1 — leaves" do
    test "true/false/nil return []" do
      assert ArgumentAnalyzer.referenced_args(true) == []
      assert ArgumentAnalyzer.referenced_args(false) == []
      assert ArgumentAnalyzer.referenced_args(nil) == []
    end

    test "bare template tuple is detected" do
      assert ArgumentAnalyzer.referenced_args({:_arg, :center_id}) == [:center_id]
    end

    test "an actor template alone returns []" do
      assert ArgumentAnalyzer.referenced_args({:_actor, :id}) == []
    end

    test "plain values return []" do
      assert ArgumentAnalyzer.referenced_args(42) == []
      assert ArgumentAnalyzer.referenced_args("hello") == []
      assert ArgumentAnalyzer.referenced_args(:an_atom) == []
    end
  end

  describe "referenced_args/1 — Ash expressions" do
    test "direct-attribute == actor has no arg refs" do
      expr = expr(author_id == ^actor(:id))
      assert ArgumentAnalyzer.referenced_args(expr) == []
    end

    test "^arg(...) == actor(...) is detected" do
      expr = expr(^arg(:center_id) == ^actor(:team_id))
      assert ArgumentAnalyzer.referenced_args(expr) == [:center_id]
    end

    test "^arg(...) in ^actor(list) is detected" do
      expr = expr(^arg(:center_id) in ^actor(:own_org_unit_ids))
      assert ArgumentAnalyzer.referenced_args(expr) == [:center_id]
    end

    test "conjunction of two arg refs yields both, no duplicates" do
      expr =
        expr(
          ^arg(:center_id) in ^actor(:own_org_unit_ids) and
            ^arg(:organization_id) == ^actor(:org_id)
        )

      assert :center_id in ArgumentAnalyzer.referenced_args(expr)
      assert :organization_id in ArgumentAnalyzer.referenced_args(expr)
      assert length(ArgumentAnalyzer.referenced_args(expr)) == 2
    end

    test "same arg repeated yields a single entry" do
      expr = expr(^arg(:x) == 1 or ^arg(:x) == 2)
      assert ArgumentAnalyzer.referenced_args(expr) == [:x]
    end

    test "not(...) traverses into inner expression" do
      expr = expr(not (^arg(:x) == 1))
      assert ArgumentAnalyzer.referenced_args(expr) == [:x]
    end

    test "if(...) function wrapper exposes inner arg refs" do
      expr =
        expr(if(^arg(:enabled) == true, do: ^arg(:center_id), else: nil) == nil)

      args = ArgumentAnalyzer.referenced_args(expr)
      assert :enabled in args
      assert :center_id in args
    end

    test "exists() body arg refs surface" do
      expr = expr(exists(items, ^arg(:threshold) < amount))
      assert ArgumentAnalyzer.referenced_args(expr) == [:threshold]
    end

    test "only actor/tenant references but no arg yield []" do
      expr = expr(org_id == ^actor(:org_id) and tenant_id == ^tenant())
      assert ArgumentAnalyzer.referenced_args(expr) == []
    end
  end

  describe "references_arg?/2" do
    test "delegates to referenced_args/1" do
      expr = expr(^arg(:a) == ^arg(:b))
      assert ArgumentAnalyzer.references_arg?(expr, :a)
      assert ArgumentAnalyzer.references_arg?(expr, :b)
      refute ArgumentAnalyzer.references_arg?(expr, :c)
    end
  end

  describe "arg_to_scopes/1" do
    test "returns %{} when no scopes reference any arg" do
      # BulkItem has no ^arg(...) scopes at all
      assert ArgumentAnalyzer.arg_to_scopes(AshGrant.Test.BulkItem) == %{}
    end

    test "includes every scope (including composites) that transitively references the arg" do
      # RefundDsl has scope :at_own_unit referencing ^arg(:center_id).
      # :by_own_author and :always do not.
      map = ArgumentAnalyzer.arg_to_scopes(AshGrant.Test.Auth.RefundDsl)

      assert Map.keys(map) == [:center_id]
      assert Enum.sort(map[:center_id]) == [:at_own_unit]
    end
  end
end

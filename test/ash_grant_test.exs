defmodule AshGrantTest do
  use ExUnit.Case

  doctest AshGrant.Permission
  doctest AshGrant.Evaluator

  describe "check/1" do
    test "returns check tuple" do
      assert {AshGrant.Check, []} = AshGrant.check()
    end

    test "returns check tuple with options" do
      assert {AshGrant.Check, [action: "delete"]} = AshGrant.check(action: "delete")
    end
  end

  describe "filter_check/1" do
    test "returns filter check tuple" do
      assert {AshGrant.FilterCheck, []} = AshGrant.filter_check()
    end

    test "returns filter check tuple with options" do
      assert {AshGrant.FilterCheck, [resource: "blog"]} = AshGrant.filter_check(resource: "blog")
    end
  end
end

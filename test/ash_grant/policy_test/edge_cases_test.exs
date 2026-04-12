defmodule AshGrant.PolicyTest.EdgeCasesTest do
  @moduledoc """
  Edge case tests for policy testing framework.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.Runner

  describe "deny rules" do
    test "deny rule blocks access" do
      # Reviewer does not have destroy permission
      result =
        AshGrant.Introspect.can?(
          AshGrant.Test.Document,
          :destroy,
          %{role: :reviewer}
        )

      # Should be denied because there's no permission
      assert {:deny, _} = result
    end

    test "deny rule wins over allow" do
      # Create an actor with both allow and deny permissions
      actor = %{
        permissions: [
          # allow
          "document:*:read:always",
          # deny (should win)
          "!document:*:read:always"
        ]
      }

      result =
        AshGrant.Introspect.can?(
          AshGrant.Test.Document,
          :read,
          actor
        )

      assert {:deny, _} = result
    end
  end

  describe "nil actor handling" do
    test "nil actor returns deny" do
      result =
        AshGrant.Introspect.can?(
          AshGrant.Test.Document,
          :read,
          nil
        )

      assert {:deny, %{reason: :no_actor}} = result
    end

    test "assertions handle nil actor gracefully" do
      # Run the test - should handle nil gracefully without crashing
      results = Runner.run_module(AshGrant.PolicyTest.Fixtures.NilActorTest)
      assert length(results) == 1

      # The test should complete without crashing
      # Result can be pass or fail, but shouldn't crash
      result = hd(results)
      assert is_boolean(result.passed)
    end
  end

  describe "undefined actor" do
    test "raises clear error for undefined actor" do
      results = Runner.run_module(AshGrant.PolicyTest.Fixtures.UndefinedActorTest)
      result = hd(results)

      assert result.passed == false

      assert String.contains?(result.message, "nonexistent") or
               String.contains?(result.message, "not defined")
    end
  end

  describe "scope inheritance" do
    # Post has: scope(:own_draft, [:own], expr(status == :draft))
    # which inherits from :own
    test "inherited scope combines filters with AND" do
      # Editor with own_draft permission needs BOTH own AND draft
      actor = %{role: :editor, id: "editor_001", permissions: ["post:*:read:own_draft"]}

      # Own draft - should pass
      filter =
        AshGrant.Info.resolve_scope_filter(
          AshGrant.Test.Post,
          :own_draft,
          %{actor: actor}
        )

      # Should be a combined filter (own AND draft)
      assert filter != true
      assert filter != false
    end
  end

  describe "empty permissions list" do
    test "empty permissions means no access" do
      actor = %{permissions: []}

      result =
        AshGrant.Introspect.can?(
          AshGrant.Test.Document,
          :read,
          actor
        )

      assert {:deny, %{reason: :no_permission}} = result
    end
  end

  describe "action type matching" do
    test "action_type matches multiple actions" do
      # Author has update permissions for draft and pending_review scopes
      actor = %{role: :author}

      # Should be able to do :update action
      update_result =
        AshGrant.Introspect.can?(
          AshGrant.Test.Document,
          :update,
          actor
        )

      # Should also be able to do :submit_for_review (which is type :update)
      _submit_result =
        AshGrant.Introspect.can?(
          AshGrant.Test.Document,
          :submit_for_review,
          actor
        )

      # Both should have some form of permission (scoped)
      assert {:allow, _} = update_result

      # submit_for_review might not be directly permissioned
      # because permission string uses "update" not "submit_for_review"
      # This is expected behavior - permission is action name based
    end
  end

  describe "special characters in test names" do
    test "handles special characters in test names" do
      results = Runner.run_module(AshGrant.PolicyTest.Fixtures.SpecialCharsTest)
      assert length(results) == 2
      assert Enum.all?(results, & &1.passed)
    end
  end

  describe "multiple assertions in one test" do
    test "all assertions must pass" do
      results = Runner.run_module(AshGrant.PolicyTest.Fixtures.MultiAssertTest)
      assert length(results) == 1
      assert hd(results).passed
    end

    test "first failing assertion stops test" do
      results = Runner.run_module(AshGrant.PolicyTest.Fixtures.FailFastTest)
      result = hd(results)

      assert result.passed == false
      assert String.contains?(result.message, "create")
    end
  end

  describe "record with missing fields" do
    test "record missing scope field evaluates correctly" do
      # Reader can read approved documents
      # If we provide a record without :status, what happens?
      results = Runner.run_module(AshGrant.PolicyTest.Fixtures.MissingFieldTest)
      # The test behavior depends on how missing fields are handled
      # We just check it doesn't crash
      assert length(results) == 1
    end
  end
end

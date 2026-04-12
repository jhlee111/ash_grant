defmodule AshGrant.SimplifyCallbackTest do
  @moduledoc """
  Tests for Ash.Policy.Check.simplify/2 and related callbacks.

  These callbacks help Ash's SAT solver make smarter authorization decisions
  by understanding relationships between checks.
  """

  use ExUnit.Case, async: true

  alias AshGrant.Check
  alias AshGrant.FilterCheck

  # Test resource for context
  defmodule TestResource do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:author_id, :uuid, public?: true)
    end

    actions do
      defaults([:read, :create, :update, :destroy])
    end
  end

  describe "AshGrant.Check.simplify/2" do
    test "returns a valid expression" do
      ref = {Check, []}
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)

      # Should return a Crux expression (at minimum, the ref itself)
      assert result != nil
    end

    test "returns ref unchanged for basic check" do
      ref = {Check, []}
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)

      # Default behavior: return ref unchanged
      assert result == ref
    end

    test "returns ref unchanged with action option" do
      ref = {Check, [action: "update"]}
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)

      assert result == ref
    end

    test "returns ref unchanged with resource option" do
      ref = {Check, [resource: "post"]}
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)

      assert result == ref
    end

    test "returns ref unchanged with multiple options" do
      ref = {Check, [action: "publish", resource: "article"]}
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)

      assert result == ref
    end
  end

  describe "AshGrant.FilterCheck.simplify/2" do
    test "returns a valid expression" do
      ref = {FilterCheck, []}
      context = %{resource: TestResource}

      result = FilterCheck.simplify(ref, context)

      assert result != nil
    end

    test "returns ref unchanged for basic check" do
      ref = {FilterCheck, []}
      context = %{resource: TestResource}

      result = FilterCheck.simplify(ref, context)

      assert result == ref
    end

    test "returns ref unchanged with action option" do
      ref = {FilterCheck, [action: "read"]}
      context = %{resource: TestResource}

      result = FilterCheck.simplify(ref, context)

      assert result == ref
    end
  end

  describe "AshGrant.Check.implies?/3" do
    test "same check implies itself" do
      ref1 = {Check, []}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      # Same check with same options implies itself
      assert Check.implies?(ref1, ref2, context) == true
    end

    test "same check with same options implies itself" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, [action: "update"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == true
    end

    test "check with different action does not imply" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, [action: "destroy"]}
      context = %{resource: TestResource}

      # Different actions don't imply each other
      assert Check.implies?(ref1, ref2, context) == false
    end

    test "check with different resource does not imply" do
      ref1 = {Check, [resource: "post"]}
      ref2 = {Check, [resource: "comment"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end

    test "check without options does not imply check with options" do
      ref1 = {Check, []}
      ref2 = {Check, [action: "update"]}
      context = %{resource: TestResource}

      # Generic check doesn't imply specific check
      assert Check.implies?(ref1, ref2, context) == false
    end

    test "check with options does not imply check without options" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      # Specific check doesn't imply generic check
      assert Check.implies?(ref1, ref2, context) == false
    end

    test "different check modules don't imply each other" do
      ref1 = {Check, []}
      ref2 = {FilterCheck, []}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end
  end

  describe "AshGrant.FilterCheck.implies?/3" do
    test "same filter check implies itself" do
      ref1 = {FilterCheck, []}
      ref2 = {FilterCheck, []}
      context = %{resource: TestResource}

      assert FilterCheck.implies?(ref1, ref2, context) == true
    end

    test "same filter check with same options implies itself" do
      ref1 = {FilterCheck, [action: "read"]}
      ref2 = {FilterCheck, [action: "read"]}
      context = %{resource: TestResource}

      assert FilterCheck.implies?(ref1, ref2, context) == true
    end

    test "filter check with different action does not imply" do
      ref1 = {FilterCheck, [action: "read"]}
      ref2 = {FilterCheck, [action: "list"]}
      context = %{resource: TestResource}

      assert FilterCheck.implies?(ref1, ref2, context) == false
    end
  end

  describe "AshGrant.Check.conflicts?/3" do
    test "same check does not conflict with itself" do
      ref1 = {Check, []}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      # Same check can't conflict with itself
      assert Check.conflicts?(ref1, ref2, context) == false
    end

    test "checks with different actions don't conflict" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, [action: "destroy"]}
      context = %{resource: TestResource}

      # Different actions don't inherently conflict
      assert Check.conflicts?(ref1, ref2, context) == false
    end

    test "checks with different resources don't conflict" do
      ref1 = {Check, [resource: "post"]}
      ref2 = {Check, [resource: "comment"]}
      context = %{resource: TestResource}

      assert Check.conflicts?(ref1, ref2, context) == false
    end

    test "check and filter_check don't conflict" do
      ref1 = {Check, []}
      ref2 = {FilterCheck, []}
      context = %{resource: TestResource}

      # Different check types don't conflict
      assert Check.conflicts?(ref1, ref2, context) == false
    end
  end

  describe "AshGrant.FilterCheck.conflicts?/3" do
    test "same filter check does not conflict with itself" do
      ref1 = {FilterCheck, []}
      ref2 = {FilterCheck, []}
      context = %{resource: TestResource}

      assert FilterCheck.conflicts?(ref1, ref2, context) == false
    end

    test "filter checks with different actions don't conflict" do
      ref1 = {FilterCheck, [action: "read"]}
      ref2 = {FilterCheck, [action: "list"]}
      context = %{resource: TestResource}

      assert FilterCheck.conflicts?(ref1, ref2, context) == false
    end
  end

  describe "callback behavior contract" do
    test "simplify returns something the SAT solver can use" do
      ref = {Check, [action: "update"]}
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)

      # The result should be usable as a SAT expression
      # At minimum it should be the ref itself or a Crux expression
      assert is_tuple(result) or is_atom(result) or is_struct(result)
    end

    test "implies? is reflexive for identical refs" do
      ref = {Check, [action: "update", resource: "post"]}
      context = %{resource: TestResource}

      # Reflexivity: a check always implies itself
      assert Check.implies?(ref, ref, context) == true
    end

    test "conflicts? is symmetric" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, [action: "destroy"]}
      context = %{resource: TestResource}

      # Symmetry: if A conflicts with B, then B conflicts with A
      result1 = Check.conflicts?(ref1, ref2, context)
      result2 = Check.conflicts?(ref2, ref1, context)

      assert result1 == result2
    end

    test "implies? handles module-only refs" do
      # Sometimes refs can be just the module without options
      ref1 = Check
      ref2 = Check
      context = %{resource: TestResource}

      # Should handle gracefully
      result = Check.implies?(ref1, ref2, context)
      assert is_boolean(result)
    end

    test "conflicts? handles module-only refs" do
      ref1 = Check
      ref2 = FilterCheck
      context = %{resource: TestResource}

      result = Check.conflicts?(ref1, ref2, context)
      assert is_boolean(result)
    end

    test "simplify handles module-only ref" do
      ref = Check
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)
      assert result != nil
    end
  end

  describe "edge cases - option ordering" do
    test "implies? matches regardless of option order" do
      # Options in different order should still be considered equal
      ref1 = {Check, [action: "update", resource: "post"]}
      ref2 = {Check, [resource: "post", action: "update"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == true
    end

    test "implies? matches with multiple options in different order" do
      ref1 = {FilterCheck, [action: "read", resource: "article"]}
      ref2 = {FilterCheck, [resource: "article", action: "read"]}
      context = %{resource: TestResource}

      assert FilterCheck.implies?(ref1, ref2, context) == true
    end
  end

  describe "edge cases - context variations" do
    test "simplify works with empty context" do
      ref = {Check, [action: "update"]}
      context = %{}

      result = Check.simplify(ref, context)
      assert result == ref
    end

    test "implies? works with empty context" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, [action: "update"]}
      context = %{}

      assert Check.implies?(ref1, ref2, context) == true
    end

    test "conflicts? works with empty context" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, [action: "destroy"]}
      context = %{}

      assert Check.conflicts?(ref1, ref2, context) == false
    end

    test "simplify works with extra context fields" do
      ref = {Check, [action: "update"]}
      context = %{resource: TestResource, actor: %{id: "123"}, extra: "ignored"}

      result = Check.simplify(ref, context)
      assert result == ref
    end
  end

  describe "edge cases - unusual refs" do
    test "implies? handles ref with empty options list" do
      ref1 = {Check, []}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == true
    end

    test "module-only ref equals tuple with empty options" do
      # Check and {Check, []} should be treated as equivalent
      ref1 = Check
      ref2 = {Check, []}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == true
    end

    test "FilterCheck module-only ref equals tuple with empty options" do
      ref1 = FilterCheck
      ref2 = {FilterCheck, []}
      context = %{resource: TestResource}

      assert FilterCheck.implies?(ref1, ref2, context) == true
    end

    test "simplify preserves unknown options" do
      # Unknown options should be preserved, not stripped
      ref = {Check, [action: "update", custom_opt: "value"]}
      context = %{resource: TestResource}

      result = Check.simplify(ref, context)
      assert result == ref
    end
  end

  describe "edge cases - cross-module interactions" do
    test "Check does not imply FilterCheck even with same options" do
      ref1 = {Check, [action: "read"]}
      ref2 = {FilterCheck, [action: "read"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end

    test "FilterCheck does not imply Check even with same options" do
      ref1 = {FilterCheck, [action: "read"]}
      ref2 = {Check, [action: "read"]}
      context = %{resource: TestResource}

      assert FilterCheck.implies?(ref1, ref2, context) == false
    end

    test "Check and FilterCheck don't conflict even with same options" do
      ref1 = {Check, [action: "read"]}
      ref2 = {FilterCheck, [action: "read"]}
      context = %{resource: TestResource}

      assert Check.conflicts?(ref1, ref2, context) == false
      assert FilterCheck.conflicts?(ref1, ref2, context) == false
    end
  end

  describe "edge cases - partial option matches" do
    test "check with subset of options does not imply check with more options" do
      ref1 = {Check, [action: "update"]}
      ref2 = {Check, [action: "update", resource: "post"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end

    test "check with more options does not imply check with fewer options" do
      ref1 = {Check, [action: "update", resource: "post"]}
      ref2 = {Check, [action: "update"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end

    test "same action but different resource does not imply" do
      ref1 = {Check, [action: "update", resource: "post"]}
      ref2 = {Check, [action: "update", resource: "comment"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end

    test "same resource but different action does not imply" do
      ref1 = {Check, [action: "update", resource: "post"]}
      ref2 = {Check, [action: "destroy", resource: "post"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end
  end

  # Tests for potential gotchas in normalize_ref
  describe "normalize_ref edge cases and gotchas" do
    test "implies? handles non-list opts gracefully" do
      # Edge case: opts is not a list (should not crash)
      ref1 = {Check, :invalid}
      ref2 = {Check, :invalid}
      context = %{resource: TestResource}

      # Should return a boolean, not crash
      result = Check.implies?(ref1, ref2, context)
      assert is_boolean(result)
    end

    test "implies? returns false for malformed refs vs valid refs" do
      ref1 = {Check, :invalid}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      # Malformed ref should not match valid ref
      assert Check.implies?(ref1, ref2, context) == false
    end

    test "simplify handles non-list opts gracefully" do
      ref = {Check, :invalid}
      context = %{resource: TestResource}

      # Should return the ref unchanged, not crash
      result = Check.simplify(ref, context)
      assert result == ref
    end

    test "conflicts? handles non-list opts gracefully" do
      ref1 = {Check, :invalid}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      # Should return false, not crash
      result = Check.conflicts?(ref1, ref2, context)
      assert result == false
    end

    test "implies? handles string module name" do
      # Edge case: someone passes a string instead of atom
      ref1 = {"Check", []}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      # Should not match since types differ
      result = Check.implies?(ref1, ref2, context)
      assert result == false
    end

    test "implies? handles nil in tuple" do
      ref1 = {nil, []}
      ref2 = {Check, []}
      context = %{resource: TestResource}

      # nil is an atom, so this should work
      result = Check.implies?(ref1, ref2, context)
      assert result == false
    end

    test "implies? with deeply nested opts" do
      # Complex options should still be compared correctly
      ref1 = {Check, [action: "update", metadata: %{nested: [1, 2, 3]}]}
      ref2 = {Check, [action: "update", metadata: %{nested: [1, 2, 3]}]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == true
    end

    test "implies? with different nested opts" do
      ref1 = {Check, [action: "update", metadata: %{nested: [1, 2, 3]}]}
      ref2 = {Check, [action: "update", metadata: %{nested: [1, 2, 4]}]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == false
    end

    test "implies? normalizes option order for complex options" do
      ref1 = {Check, [z_option: "last", a_option: "first"]}
      ref2 = {Check, [a_option: "first", z_option: "last"]}
      context = %{resource: TestResource}

      assert Check.implies?(ref1, ref2, context) == true
    end

    test "FilterCheck implies? handles malformed refs" do
      ref1 = {FilterCheck, :invalid}
      ref2 = {FilterCheck, []}
      context = %{resource: TestResource}

      result = FilterCheck.implies?(ref1, ref2, context)
      assert result == false
    end
  end

  # Tests for strict_check integration
  describe "strict_check integration" do
    # Verify that our callbacks don't interfere with the normal
    # strict_check -> match? flow in SimpleCheck

    test "Check module has strict_check callback" do
      # SimpleCheck should provide strict_check automatically
      assert function_exported?(Check, :strict_check, 3)
    end

    test "FilterCheck module has strict_check callback" do
      # FilterCheck should provide strict_check automatically
      assert function_exported?(FilterCheck, :strict_check, 3)
    end

    test "Check module has type callback" do
      assert function_exported?(Check, :type, 0)
    end

    test "FilterCheck module has type callback" do
      assert function_exported?(FilterCheck, :type, 0)
    end

    test "all required callbacks are exported for Check" do
      # Verify Check exports all the callbacks we implemented
      assert function_exported?(Check, :simplify, 2)
      assert function_exported?(Check, :implies?, 3)
      assert function_exported?(Check, :conflicts?, 3)
      assert function_exported?(Check, :describe, 1)
      assert function_exported?(Check, :match?, 3)
    end

    test "all required callbacks are exported for FilterCheck" do
      assert function_exported?(FilterCheck, :simplify, 2)
      assert function_exported?(FilterCheck, :implies?, 3)
      assert function_exported?(FilterCheck, :conflicts?, 3)
      assert function_exported?(FilterCheck, :describe, 1)
      assert function_exported?(FilterCheck, :filter, 3)
    end
  end

  # Integration tests to verify callbacks work with Ash's policy evaluation
  describe "integration with Ash.can?" do
    # These tests use an in-memory resource to verify the callbacks integrate
    # properly with Ash's policy system without requiring database access

    defmodule IntegrationDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(AshGrant.SimplifyCallbackTest.IntegrationPost)
      end
    end

    defmodule IntegrationPost do
      use Ash.Resource,
        domain: AshGrant.SimplifyCallbackTest.IntegrationDomain,
        data_layer: Ash.DataLayer.Ets,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshGrant]

      ash_grant do
        resolver(fn actor, _context ->
          case actor do
            nil -> []
            %{permissions: perms} -> perms
            _ -> []
          end
        end)

        resource_name("integration_post")
        scope(:always, true)
        scope(:own, expr(author_id == ^actor(:id)))
      end

      policies do
        policy action_type(:read) do
          authorize_if(AshGrant.filter_check())
        end

        policy action_type([:create, :update, :destroy]) do
          authorize_if(AshGrant.check())
        end
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:title, :string, public?: true)
        attribute(:author_id, :uuid, public?: true)
      end

      actions do
        defaults([:read, :create, :update, :destroy])
      end
    end

    test "Ash.can? works with simplify callbacks for read action" do
      actor = %{id: Ash.UUID.generate(), permissions: ["integration_post:*:read:always"]}

      # Should be able to read
      assert Ash.can?({IntegrationPost, :read}, actor) == true
    end

    test "Ash.can? works with simplify callbacks for create action" do
      actor = %{id: Ash.UUID.generate(), permissions: ["integration_post:*:create:always"]}

      # Should be able to create
      assert Ash.can?({IntegrationPost, :create}, actor) == true
    end

    test "Ash.can? denies when no permissions" do
      actor = %{id: Ash.UUID.generate(), permissions: []}

      # Should not be able to read without permissions
      assert Ash.can?({IntegrationPost, :read}, actor) == false
    end

    test "Ash.can? denies nil actor" do
      # Nil actor should be denied
      assert Ash.can?({IntegrationPost, :read}, nil) == false
    end

    test "policy evaluation uses AshGrant checks with simplify callbacks" do
      # This test verifies that the simplify/implies/conflicts callbacks
      # don't break the normal policy evaluation flow
      actor_with_read = %{
        id: Ash.UUID.generate(),
        permissions: ["integration_post:*:read:always"]
      }

      actor_with_write = %{
        id: Ash.UUID.generate(),
        permissions: ["integration_post:*:update:always"]
      }

      actor_with_both = %{
        id: Ash.UUID.generate(),
        permissions: ["integration_post:*:read:always", "integration_post:*:update:always"]
      }

      # Read-only actor
      assert Ash.can?({IntegrationPost, :read}, actor_with_read) == true
      assert Ash.can?({IntegrationPost, :update}, actor_with_read) == false

      # Write-only actor
      assert Ash.can?({IntegrationPost, :read}, actor_with_write) == false
      assert Ash.can?({IntegrationPost, :update}, actor_with_write) == true

      # Actor with both permissions
      assert Ash.can?({IntegrationPost, :read}, actor_with_both) == true
      assert Ash.can?({IntegrationPost, :update}, actor_with_both) == true
    end

    test "multiple policy checks with same options handled correctly" do
      # Verifies that implies?/3 returning true for same checks doesn't
      # cause issues with policy evaluation
      actor = %{id: Ash.UUID.generate(), permissions: ["integration_post:*:read:always"]}

      # Multiple calls should all succeed
      assert Ash.can?({IntegrationPost, :read}, actor) == true
      assert Ash.can?({IntegrationPost, :read}, actor) == true
      assert Ash.can?({IntegrationPost, :read}, actor) == true
    end
  end
end

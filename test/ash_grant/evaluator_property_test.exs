defmodule AshGrant.EvaluatorPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrant.{Evaluator, Permission}

  # Generators

  defp resource_gen do
    string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
  end

  defp action_gen do
    string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
  end

  defp scope_gen do
    one_of([
      constant("all"),
      constant("own"),
      constant("published"),
      string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
    ])
  end

  defp instance_id_gen do
    tuple({
      string(:alphanumeric, min_length: 2, max_length: 5) |> map(&String.downcase/1),
      string(:alphanumeric, min_length: 10, max_length: 15)
    })
    |> map(fn {prefix, suffix} -> "#{prefix}_#{suffix}" end)
  end

  # Property Tests

  describe "has_access?/3 deny-wins semantics" do
    property "if any deny matches, access is denied regardless of allow" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        # Create permissions with both allow and deny for same resource/action
        permissions = [
          # allow
          "#{resource}:*:#{action}:#{scope}",
          # deny
          "!#{resource}:*:#{action}:#{scope}"
        ]

        # Deny should win
        refute Evaluator.has_access?(permissions, resource, action)
      end
    end

    property "deny wins regardless of permission order" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        allow = "#{resource}:*:#{action}:#{scope}"
        deny = "!#{resource}:*:#{action}:#{scope}"

        # Test both orders
        assert Evaluator.has_access?([allow], resource, action) == true
        refute Evaluator.has_access?([allow, deny], resource, action)
        refute Evaluator.has_access?([deny, allow], resource, action)
      end
    end

    property "empty permission list always denies" do
      check all(
              resource <- resource_gen(),
              action <- action_gen()
            ) do
        refute Evaluator.has_access?([], resource, action)
      end
    end
  end

  describe "has_instance_access?/3 deny-wins semantics" do
    property "if any deny matches instance, access is denied" do
      check all(
              resource <- resource_gen(),
              instance_id <- instance_id_gen(),
              action <- action_gen()
            ) do
        permissions = [
          "#{resource}:#{instance_id}:#{action}:",
          "!#{resource}:#{instance_id}:#{action}:"
        ]

        refute Evaluator.has_instance_access?(permissions, instance_id, action)
      end
    end
  end

  describe "get_scope/3 consistency" do
    property "returns nil when access is denied" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        permissions = [
          "#{resource}:*:#{action}:#{scope}",
          # deny
          "!#{resource}:*:#{action}:all"
        ]

        assert Evaluator.get_scope(permissions, resource, action) == nil
      end
    end

    property "returns scope when access is allowed" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        permissions = ["#{resource}:*:#{action}:#{scope}"]

        assert Evaluator.get_scope(permissions, resource, action) == scope
      end
    end
  end

  describe "get_all_scopes/3 consistency" do
    property "returns empty list when denied" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scopes <- list_of(scope_gen(), min_length: 1, max_length: 3)
            ) do
        allow_perms = Enum.map(scopes, &"#{resource}:*:#{action}:#{&1}")
        deny_perm = "!#{resource}:*:#{action}:all"

        assert Evaluator.get_all_scopes(allow_perms ++ [deny_perm], resource, action) == []
      end
    end

    property "returns unique scopes" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        # Duplicate the same permission
        permissions = [
          "#{resource}:*:#{action}:#{scope}",
          "#{resource}:*:#{action}:#{scope}",
          # wildcard action, same scope
          "#{resource}:*:*:#{scope}"
        ]

        scopes = Evaluator.get_all_scopes(permissions, resource, action)
        assert scopes == Enum.uniq(scopes)
      end
    end
  end

  describe "combine/1 correctness" do
    property "combined permissions grant union of access" do
      check all(
              resource1 <- resource_gen(),
              resource2 <- resource_gen() |> filter(&(&1 != resource1)),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        list1 = ["#{resource1}:*:#{action}:#{scope}"]
        list2 = ["#{resource2}:*:#{action}:#{scope}"]

        combined = Evaluator.combine([list1, list2])

        assert Evaluator.has_access?(combined, resource1, action)
        assert Evaluator.has_access?(combined, resource2, action)
      end
    end

    property "combined empty lists remain empty" do
      check all(
              resource <- resource_gen(),
              action <- action_gen()
            ) do
        combined = Evaluator.combine([[], [], []])

        refute Evaluator.has_access?(combined, resource, action)
      end
    end
  end

  describe "find_matching/3 completeness" do
    property "find_matching returns all relevant permissions including deny" do
      check all(
              resource <- resource_gen(),
              action <- action_gen(),
              scope <- scope_gen()
            ) do
        allow = "#{resource}:*:#{action}:#{scope}"
        deny = "!#{resource}:*:#{action}:all"
        other = "other:*:#{action}:#{scope}"

        permissions = [allow, deny, other]
        matching = Evaluator.find_matching(permissions, resource, action)

        # Should find both allow and deny, but not "other"
        assert length(matching) == 2

        matching_strs = Enum.map(matching, &Permission.to_string/1)
        assert Enum.any?(matching_strs, &String.contains?(&1, resource))
        refute Enum.any?(matching_strs, &String.starts_with?(&1, "other"))
      end
    end
  end

  describe "wildcard matching" do
    property "resource wildcard * matches any resource" do
      check all(
              resource <- resource_gen(),
              action <- action_gen()
            ) do
        permissions = ["*:*:#{action}:all"]

        assert Evaluator.has_access?(permissions, resource, action)
      end
    end

    property "action wildcard * matches any action" do
      check all(
              resource <- resource_gen(),
              action <- action_gen()
            ) do
        permissions = ["#{resource}:*:*:all"]

        assert Evaluator.has_access?(permissions, resource, action)
      end
    end

    property "action prefix wildcard matches prefixed actions" do
      check all(
              resource <- resource_gen(),
              prefix <-
                string(:alphanumeric, min_length: 2, max_length: 5) |> map(&String.downcase/1),
              suffix <-
                string(:alphanumeric, min_length: 1, max_length: 5) |> map(&String.downcase/1)
            ) do
        permissions = ["#{resource}:*:#{prefix}*:all"]
        action = "#{prefix}#{suffix}"

        assert Evaluator.has_access?(permissions, resource, action)
      end
    end
  end

  describe "RBAC vs Instance separation" do
    property "RBAC permission does not grant instance access" do
      check all(
              resource <- resource_gen(),
              instance_id <- instance_id_gen(),
              action <- action_gen()
            ) do
        permissions = ["#{resource}:*:#{action}:all"]

        assert Evaluator.has_access?(permissions, resource, action)
        refute Evaluator.has_instance_access?(permissions, instance_id, action)
      end
    end

    property "Instance permission does not grant RBAC access" do
      check all(
              resource <- resource_gen(),
              instance_id <- instance_id_gen(),
              action <- action_gen()
            ) do
        permissions = ["#{resource}:#{instance_id}:#{action}:"]

        assert Evaluator.has_instance_access?(permissions, instance_id, action)
        refute Evaluator.has_access?(permissions, resource, action)
      end
    end
  end
end

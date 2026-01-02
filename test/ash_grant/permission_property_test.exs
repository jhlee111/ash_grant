defmodule AshGrant.PermissionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrant.Permission

  # Generators

  defp resource_gen do
    one_of([
      constant("*"),
      string(:alphanumeric, min_length: 1, max_length: 20)
      |> filter(&(&1 != "*"))
      |> map(&String.downcase/1)
    ])
  end

  defp instance_id_gen do
    one_of([
      constant("*"),
      # Prefixed ID style: prefix_alphanumeric
      tuple({
        string(:alphanumeric, min_length: 2, max_length: 10) |> map(&String.downcase/1),
        string(:alphanumeric, min_length: 10, max_length: 20)
      })
      |> map(fn {prefix, suffix} -> "#{prefix}_#{suffix}" end)
    ])
  end

  defp action_gen do
    one_of([
      constant("*"),
      string(:alphanumeric, min_length: 1, max_length: 20)
      |> filter(&(&1 != "*"))
      |> map(&String.downcase/1),
      # Wildcard suffix like read*
      string(:alphanumeric, min_length: 2, max_length: 15)
      |> map(&(String.downcase(&1) <> "*"))
    ])
  end

  defp scope_gen do
    one_of([
      constant(nil),
      string(:alphanumeric, min_length: 1, max_length: 20) |> map(&String.downcase/1)
    ])
  end

  defp deny_gen do
    boolean()
  end

  defp permission_struct_gen do
    gen all(
          resource <- resource_gen(),
          instance_id <- instance_id_gen(),
          action <- action_gen(),
          scope <- scope_gen(),
          deny <- deny_gen()
        ) do
      %Permission{
        resource: resource,
        instance_id: instance_id,
        action: action,
        scope: scope,
        deny: deny
      }
    end
  end

  # Property Tests

  describe "parse/1 and to_string/1 roundtrip" do
    property "to_string |> parse returns equivalent permission" do
      check all(perm <- permission_struct_gen()) do
        str = Permission.to_string(perm)
        {:ok, parsed} = Permission.parse(str)

        # Compare all fields
        assert parsed.resource == perm.resource
        assert parsed.instance_id == (perm.instance_id || "*")
        assert parsed.action == perm.action
        assert parsed.scope == perm.scope
        assert parsed.deny == perm.deny
      end
    end

    property "parse |> to_string |> parse returns same result" do
      check all(perm <- permission_struct_gen()) do
        str1 = Permission.to_string(perm)
        {:ok, parsed1} = Permission.parse(str1)
        str2 = Permission.to_string(parsed1)
        {:ok, parsed2} = Permission.parse(str2)

        assert parsed1.resource == parsed2.resource
        assert parsed1.instance_id == parsed2.instance_id
        assert parsed1.action == parsed2.action
        assert parsed1.scope == parsed2.scope
        assert parsed1.deny == parsed2.deny
      end
    end

    property "to_string always produces valid parseable string" do
      check all(perm <- permission_struct_gen()) do
        str = Permission.to_string(perm)
        assert {:ok, _} = Permission.parse(str)
      end
    end
  end

  describe "String.Chars protocol consistency" do
    property "String.Chars.to_string matches Permission.to_string" do
      check all(perm <- permission_struct_gen()) do
        assert "#{perm}" == Permission.to_string(perm)
      end
    end
  end

  describe "deny prefix handling" do
    property "deny flag is preserved through roundtrip" do
      check all(perm <- permission_struct_gen()) do
        str = Permission.to_string(perm)
        {:ok, parsed} = Permission.parse(str)

        if perm.deny do
          assert String.starts_with?(str, "!")
          assert parsed.deny == true
        else
          refute String.starts_with?(str, "!")
          assert parsed.deny == false
        end
      end
    end
  end

  describe "instance_permission? consistency" do
    property "instance_permission? returns true iff instance_id != *" do
      check all(perm <- permission_struct_gen()) do
        str = Permission.to_string(perm)
        {:ok, parsed} = Permission.parse(str)

        if parsed.instance_id == "*" do
          refute Permission.instance_permission?(parsed)
        else
          assert Permission.instance_permission?(parsed)
        end
      end
    end
  end

  describe "matches?/3 correctness" do
    property "exact match always succeeds for RBAC permissions" do
      check all(
              resource <- resource_gen() |> filter(&(&1 != "*")),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              scope <- scope_gen()
            ) do
        perm = %Permission{
          resource: resource,
          instance_id: "*",
          action: action,
          scope: scope,
          deny: false
        }

        assert Permission.matches?(perm, resource, action)
      end
    end

    property "wildcard resource (*) matches any resource" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        perm = %Permission{
          resource: "*",
          instance_id: "*",
          action: action,
          scope: "all",
          deny: false
        }

        assert Permission.matches?(perm, resource, action)
      end
    end

    property "wildcard action (*) matches any action" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        perm = %Permission{
          resource: resource,
          instance_id: "*",
          action: "*",
          scope: "all",
          deny: false
        }

        assert Permission.matches?(perm, resource, action)
      end
    end

    property "action prefix wildcard (read*) matches actions starting with prefix" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              prefix <-
                string(:alphanumeric, min_length: 2, max_length: 5) |> map(&String.downcase/1),
              suffix <-
                string(:alphanumeric, min_length: 0, max_length: 10) |> map(&String.downcase/1)
            ) do
        perm = %Permission{
          resource: resource,
          instance_id: "*",
          action: "#{prefix}*",
          scope: "all",
          deny: false
        }

        # Should match action that starts with prefix
        assert Permission.matches?(perm, resource, "#{prefix}#{suffix}")
      end
    end

    property "instance permission does not match RBAC query" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              instance_id <-
                tuple({
                  string(:alphanumeric, min_length: 2, max_length: 5) |> map(&String.downcase/1),
                  string(:alphanumeric, min_length: 10, max_length: 15)
                })
                |> map(fn {p, s} -> "#{p}_#{s}" end),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        perm = %Permission{
          resource: resource,
          instance_id: instance_id,
          action: action,
          scope: nil,
          deny: false
        }

        # Instance permission should NOT match RBAC query
        refute Permission.matches?(perm, resource, action)
      end
    end
  end

  describe "matches_instance?/3 correctness" do
    property "exact instance match succeeds" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              instance_id <-
                tuple({
                  string(:alphanumeric, min_length: 2, max_length: 5) |> map(&String.downcase/1),
                  string(:alphanumeric, min_length: 10, max_length: 15)
                })
                |> map(fn {p, s} -> "#{p}_#{s}" end),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        perm = %Permission{
          resource: resource,
          instance_id: instance_id,
          action: action,
          scope: nil,
          deny: false
        }

        assert Permission.matches_instance?(perm, instance_id, action)
      end
    end

    property "RBAC permission does not match instance query" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              instance_id <-
                tuple({
                  string(:alphanumeric, min_length: 2, max_length: 5) |> map(&String.downcase/1),
                  string(:alphanumeric, min_length: 10, max_length: 15)
                })
                |> map(fn {p, s} -> "#{p}_#{s}" end),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        perm = %Permission{
          resource: resource,
          instance_id: "*",
          action: action,
          scope: "all",
          deny: false
        }

        # RBAC permission should NOT match instance query
        refute Permission.matches_instance?(perm, instance_id, action)
      end
    end

    property "different instance_id does not match" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              {prefix, suffix1} <-
                tuple({
                  string(:alphanumeric, min_length: 2, max_length: 5) |> map(&String.downcase/1),
                  string(:alphanumeric, min_length: 10, max_length: 15)
                }),
              suffix2 <-
                string(:alphanumeric, min_length: 10, max_length: 15) |> filter(&(&1 != suffix1)),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        instance_id1 = "#{prefix}_#{suffix1}"
        instance_id2 = "#{prefix}_#{suffix2}"

        perm = %Permission{
          resource: resource,
          instance_id: instance_id1,
          action: action,
          scope: nil,
          deny: false
        }

        refute Permission.matches_instance?(perm, instance_id2, action)
      end
    end
  end

  describe "legacy format compatibility" do
    property "three-part format parses with instance_id = *" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              scope <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        str = "#{resource}:#{action}:#{scope}"
        {:ok, parsed} = Permission.parse(str)

        assert parsed.resource == resource
        assert parsed.instance_id == "*"
        assert parsed.action == action
        assert parsed.scope == scope
      end
    end

    property "two-part format parses with instance_id = * and scope = nil" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        str = "#{resource}:#{action}"
        {:ok, parsed} = Permission.parse(str)

        assert parsed.resource == resource
        assert parsed.instance_id == "*"
        assert parsed.action == action
        assert parsed.scope == nil
      end
    end
  end

  describe "edge cases" do
    property "empty scope becomes nil" do
      check all(
              resource <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1),
              instance_id <- instance_id_gen(),
              action <-
                string(:alphanumeric, min_length: 1, max_length: 10) |> map(&String.downcase/1)
            ) do
        str = "#{resource}:#{instance_id}:#{action}:"
        {:ok, parsed} = Permission.parse(str)

        assert parsed.scope == nil
      end
    end

    property "single part string fails to parse" do
      check all(single <- string(:alphanumeric, min_length: 1, max_length: 20)) do
        assert {:error, _} = Permission.parse(single)
      end
    end
  end
end

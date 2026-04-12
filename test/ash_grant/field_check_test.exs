defmodule AshGrant.FieldCheckTest do
  use ExUnit.Case, async: true

  describe "field_check/1" do
    test "creates check tuple with field_group option" do
      assert {AshGrant.FieldCheck, [field_group: :sensitive]} = AshGrant.field_check(:sensitive)
    end

    test "creates check tuple via FieldCheck module" do
      assert {AshGrant.FieldCheck, [field_group: :confidential]} =
               AshGrant.FieldCheck.field_check(:confidential)
    end
  end

  describe "describe/1" do
    test "returns human-readable description" do
      desc = AshGrant.FieldCheck.describe(field_group: :sensitive)
      assert desc =~ "sensitive"
      assert desc =~ "field group"
    end
  end

  describe "inherits_from? logic" do
    # SensitiveRecord has: :public -> :sensitive -> :confidential
    # We test the inheritance chain via Info helpers

    test "confidential inherits from sensitive" do
      fg = AshGrant.Info.get_field_group(AshGrant.Test.SensitiveRecord, :confidential)
      assert :sensitive in fg.inherits
    end

    test "sensitive inherits from public" do
      fg = AshGrant.Info.get_field_group(AshGrant.Test.SensitiveRecord, :sensitive)
      assert :public in fg.inherits
    end

    test "public has no parents" do
      fg = AshGrant.Info.get_field_group(AshGrant.Test.SensitiveRecord, :public)
      assert fg.inherits == nil or fg.inherits == []
    end
  end

  describe "match?/3 with mock authorizer" do
    # Build a minimal authorizer-like map that FieldCheck can use
    defp build_authorizer(opts \\ []) do
      resource = Keyword.get(opts, :resource, AshGrant.Test.SensitiveRecord)
      action_name = Keyword.get(opts, :action, :read)

      %{
        resource: resource,
        action: %{name: action_name, type: :read},
        query: %{tenant: nil},
        changeset: nil
      }
    end

    test "nil actor returns false" do
      authorizer = build_authorizer()
      refute AshGrant.FieldCheck.match?(nil, authorizer, field_group: :public)
    end

    test "actor with 5-part permission matching the required group passes" do
      # Actor has sensitiverecord:*:read:always:sensitive (exactly the required group)
      actor = %{permissions: ["sensitiverecord:*:read:always:sensitive"]}
      authorizer = build_authorizer()

      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :sensitive)
    end

    test "actor with higher field group (confidential) passes for lower group (sensitive)" do
      # :confidential inherits :sensitive, so having confidential grants access to sensitive
      actor = %{permissions: ["sensitiverecord:*:read:always:confidential"]}
      authorizer = build_authorizer()

      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :sensitive)
    end

    test "actor with higher field group (confidential) passes for public group" do
      # :confidential -> :sensitive -> :public (transitive inheritance)
      actor = %{permissions: ["sensitiverecord:*:read:always:confidential"]}
      authorizer = build_authorizer()

      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :public)
    end

    test "actor with lower field group (public) fails for higher group (sensitive)" do
      # :public does NOT inherit from :sensitive
      actor = %{permissions: ["sensitiverecord:*:read:always:public"]}
      authorizer = build_authorizer()

      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :sensitive)
    end

    test "actor with lower field group (public) fails for confidential group" do
      actor = %{permissions: ["sensitiverecord:*:read:always:public"]}
      authorizer = build_authorizer()

      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :confidential)
    end

    test "actor with 4-part permission (no field_group) passes - unrestricted field access" do
      # No field_group in permission means no field restrictions
      actor = %{permissions: ["sensitiverecord:*:read:always"]}
      authorizer = build_authorizer()

      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :confidential)
    end

    test "actor with no matching resource permission fails" do
      # Actor has permission for a different resource
      actor = %{permissions: ["other_resource:*:read:always"]}
      authorizer = build_authorizer()

      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :public)
    end

    test "actor with denied permission fails even with field_group" do
      # Deny permission should block access
      actor = %{
        permissions: [
          "sensitiverecord:*:read:always:confidential",
          "!sensitiverecord:*:read:always"
        ]
      }

      authorizer = build_authorizer()

      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :confidential)
    end

    test "sensitive group grants access to sensitive but not confidential" do
      actor = %{permissions: ["sensitiverecord:*:read:always:sensitive"]}
      authorizer = build_authorizer()

      # :sensitive includes :public (via inheritance)
      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :public)
      # :sensitive is itself
      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :sensitive)
      # :sensitive does NOT include :confidential
      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :confidential)
    end

    test "5-part deny on field_group blocks access" do
      actor = %{
        permissions: [
          "sensitiverecord:*:read:always:confidential",
          "!sensitiverecord:*:read:always:sensitive"
        ]
      }

      authorizer = build_authorizer()

      # deny-wins: deny matches resource+action, blocks all field access
      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :confidential)
      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :public)
    end

    test "5-part with action wildcard grants field access" do
      actor = %{permissions: ["sensitiverecord:*:*:always:confidential"]}
      authorizer = build_authorizer()

      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :confidential)
      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :sensitive)
      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :public)
    end

    test "5-part with resource wildcard grants field access" do
      actor = %{permissions: ["*:*:read:always:sensitive"]}
      authorizer = build_authorizer()

      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :sensitive)
      assert AshGrant.FieldCheck.match?(actor, authorizer, field_group: :public)
      refute AshGrant.FieldCheck.match?(actor, authorizer, field_group: :confidential)
    end
  end
end

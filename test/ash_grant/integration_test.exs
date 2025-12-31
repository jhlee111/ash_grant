defmodule AshGrant.IntegrationTest do
  @moduledoc """
  Integration tests that verify AshGrant works correctly with Ash resources.

  These tests create complete Ash resources with policies and verify
  that permission checks work end-to-end.
  """
  use ExUnit.Case, async: true

  alias AshGrant.{Evaluator, Info}

  # === Test Domain and Resources ===

  defmodule TestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshGrant.IntegrationTest.Post
      resource AshGrant.IntegrationTest.Comment
    end
  end

  defmodule Post do
    use Ash.Resource,
      domain: AshGrant.IntegrationTest.TestDomain,
      extensions: [AshGrant]

    ash_grant do
      resolver fn actor, _context ->
        case actor do
          nil -> []
          %{permissions: perms} -> perms
          %{role: :admin} -> ["post:*:*:all"]
          %{role: :editor} -> ["post:*:read:all", "post:*:update:own", "post:*:create:all"]
          %{role: :viewer} -> ["post:*:read:published"]
          _ -> []
        end
      end

      resource_name "post"
      owner_field :author_id

      scope :all, true
      scope :own, expr(author_id == ^actor(:id))
      scope :published, expr(status == :published)
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :status, :atom, constraints: [one_of: [:draft, :published]], default: :draft
      attribute :author_id, :uuid
      create_timestamp :inserted_at
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        accept [:title, :status, :author_id]
      end

      update :update do
        accept [:title, :status]
      end

      update :publish do
        change set_attribute(:status, :published)
      end
    end
  end

  defmodule Comment do
    use Ash.Resource,
      domain: AshGrant.IntegrationTest.TestDomain,
      extensions: [AshGrant]

    ash_grant do
      resolver fn actor, _context ->
        case actor do
          nil -> []
          %{role: :admin} -> ["comment:*:*:all"]
          %{role: :user} -> ["comment:*:read:all", "comment:*:create:all", "comment:*:delete:own"]
          _ -> []
        end
      end

      resource_name "comment"
      owner_field :user_id

      scope :all, true
      scope :own, expr(user_id == ^actor(:id))
    end

    attributes do
      uuid_primary_key :id
      attribute :body, :string, public?: true
      attribute :user_id, :uuid
      attribute :post_id, :uuid
    end
  end

  # === Test Actors ===

  defp admin_actor do
    %{id: Ash.UUID.generate(), role: :admin}
  end

  defp editor_actor do
    %{id: Ash.UUID.generate(), role: :editor}
  end

  defp viewer_actor do
    %{id: Ash.UUID.generate(), role: :viewer}
  end

  defp custom_perms_actor(perms) do
    %{id: Ash.UUID.generate(), permissions: perms}
  end

  # === Permission Resolution Tests ===

  describe "permission resolution" do
    test "admin gets full access permissions" do
      actor = admin_actor()
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      assert Evaluator.has_access?(permissions, "post", "read")
      assert Evaluator.has_access?(permissions, "post", "create")
      assert Evaluator.has_access?(permissions, "post", "update")
      assert Evaluator.has_access?(permissions, "post", "delete")
    end

    test "editor gets limited permissions" do
      actor = editor_actor()
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      assert Evaluator.has_access?(permissions, "post", "read")
      assert Evaluator.has_access?(permissions, "post", "create")
      assert Evaluator.has_access?(permissions, "post", "update")
      refute Evaluator.has_access?(permissions, "post", "delete")
    end

    test "viewer gets read-only permissions" do
      actor = viewer_actor()
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      assert Evaluator.has_access?(permissions, "post", "read")
      refute Evaluator.has_access?(permissions, "post", "create")
      refute Evaluator.has_access?(permissions, "post", "update")
      refute Evaluator.has_access?(permissions, "post", "delete")
    end

    test "nil actor gets no permissions" do
      resolver = Info.resolver(Post)
      permissions = resolver.(nil, %{})

      assert permissions == []
      refute Evaluator.has_access?(permissions, "post", "read")
    end
  end

  describe "scope resolution" do
    test "admin gets 'all' scope" do
      actor = admin_actor()
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      scope = Evaluator.get_scope(permissions, "post", "read")
      assert scope == "all"
    end

    test "editor gets 'own' scope for update" do
      actor = editor_actor()
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      scope = Evaluator.get_scope(permissions, "post", "update")
      assert scope == "own"
    end

    test "viewer gets 'published' scope for read" do
      actor = viewer_actor()
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      scope = Evaluator.get_scope(permissions, "post", "read")
      assert scope == "published"
    end
  end

  describe "scope filter resolution" do
    test "resolves 'all' scope to true" do
      filter = Info.resolve_scope_filter(Post, :all, %{})
      assert filter == true
    end

    test "resolves 'own' scope to expression" do
      filter = Info.resolve_scope_filter(Post, :own, %{})
      refute is_boolean(filter)
    end

    test "resolves 'published' scope to expression" do
      filter = Info.resolve_scope_filter(Post, :published, %{})
      refute is_boolean(filter)
    end
  end

  describe "deny-wins integration" do
    test "deny overrides allow" do
      actor = custom_perms_actor([
        "post:*:*:all",
        "!post:*:delete:all"
      ])
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      assert Evaluator.has_access?(permissions, "post", "read")
      assert Evaluator.has_access?(permissions, "post", "update")
      refute Evaluator.has_access?(permissions, "post", "delete")
    end

    test "multiple deny rules" do
      actor = custom_perms_actor([
        "post:*:*:all",
        "!post:*:delete:all",
        "!post:*:update:all"
      ])
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      assert Evaluator.has_access?(permissions, "post", "read")
      assert Evaluator.has_access?(permissions, "post", "create")
      refute Evaluator.has_access?(permissions, "post", "update")
      refute Evaluator.has_access?(permissions, "post", "delete")
    end
  end

  describe "multi-scope scenarios" do
    test "multiple scopes for same action" do
      actor = custom_perms_actor([
        "post:*:read:own",
        "post:*:read:published"
      ])
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      scopes = Evaluator.get_all_scopes(permissions, "post", "read")
      assert "own" in scopes
      assert "published" in scopes
    end
  end

  describe "instance permissions" do
    test "instance permission grants specific access" do
      post_id = "post_#{Ash.UUID.generate() |> String.replace("-", "")}"

      actor = custom_perms_actor([
        "post:#{post_id}:read:",
        "post:#{post_id}:update:"
      ])
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      assert Evaluator.has_instance_access?(permissions, post_id, "read")
      assert Evaluator.has_instance_access?(permissions, post_id, "update")
      refute Evaluator.has_instance_access?(permissions, post_id, "delete")
    end

    test "instance permission does not grant RBAC access" do
      post_id = "post_#{Ash.UUID.generate() |> String.replace("-", "")}"

      actor = custom_perms_actor([
        "post:#{post_id}:read:"
      ])
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      # Instance perm doesn't grant general RBAC access
      refute Evaluator.has_access?(permissions, "post", "read")
    end

    test "combined RBAC and instance permissions" do
      post_id = "post_#{Ash.UUID.generate() |> String.replace("-", "")}"

      actor = custom_perms_actor([
        "post:*:read:published",          # RBAC: read published posts
        "post:#{post_id}:update:"         # Instance: update specific post
      ])
      resolver = Info.resolver(Post)
      permissions = resolver.(actor, %{})

      # RBAC access
      assert Evaluator.has_access?(permissions, "post", "read")
      refute Evaluator.has_access?(permissions, "post", "update")

      # Instance access
      assert Evaluator.has_instance_access?(permissions, post_id, "update")
    end
  end

  describe "resource configuration" do
    test "configured? returns true for AshGrant resources" do
      assert Info.configured?(Post)
      assert Info.configured?(Comment)
    end

    test "resource_name is correctly configured" do
      assert Info.resource_name(Post) == "post"
      assert Info.resource_name(Comment) == "comment"
    end

    test "owner_field is correctly configured" do
      assert Info.owner_field(Post) == :author_id
      assert Info.owner_field(Comment) == :user_id
    end
  end
end

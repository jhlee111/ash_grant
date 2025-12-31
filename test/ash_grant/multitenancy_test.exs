defmodule AshGrant.MultitenancyTest do
  @moduledoc """
  Tests for multi-tenancy support in AshGrant.

  This module tests the integration of AshGrant with Ash's multi-tenancy
  features, specifically the `^tenant()` template in scope expressions.

  ## Test Coverage

  - `^tenant()` template resolution in scope filters
  - Tenant isolation for read actions (FilterCheck)
  - Tenant isolation for write actions (Check)
  - Combined tenant + ownership scopes
  - Cross-tenant access prevention

  ## Key Issue Being Tested

  Prior to the fix, `Ash.Expr.eval/2` was called without passing the
  `:tenant` option, causing `^tenant()` expressions to not resolve correctly.
  """

  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Test.TenantPost

  describe "FilterCheck with ^tenant() scope" do
    test "tenant_admin can read posts in their tenant" do
      tenant_a = Ash.UUID.generate()
      tenant_b = Ash.UUID.generate()

      # Create posts in different tenants
      post_a = generate(tenant_post(tenant_id: tenant_a))
      _post_b = generate(tenant_post(tenant_id: tenant_b))

      # Tenant admin for tenant A
      actor = %{id: Ash.UUID.generate(), role: :tenant_admin}

      # Read with tenant context - should only see tenant A's posts
      posts = TenantPost |> Ash.read!(actor: actor, tenant: tenant_a)

      assert length(posts) == 1
      assert hd(posts).id == post_a.id
    end

    test "tenant_admin cannot read posts from other tenants" do
      tenant_a = Ash.UUID.generate()
      tenant_b = Ash.UUID.generate()

      # Create post only in tenant B
      _post_b = generate(tenant_post(tenant_id: tenant_b))

      # Tenant admin for tenant A
      actor = %{id: Ash.UUID.generate(), role: :tenant_admin}

      # Read with tenant A context - should see nothing
      posts = TenantPost |> Ash.read!(actor: actor, tenant: tenant_a)

      assert posts == []
    end

    test "tenant isolation with multiple posts" do
      tenant_a = Ash.UUID.generate()
      tenant_b = Ash.UUID.generate()

      # Create multiple posts in each tenant
      posts_a = for _ <- 1..3, do: generate(tenant_post(tenant_id: tenant_a))
      _posts_b = for _ <- 1..2, do: generate(tenant_post(tenant_id: tenant_b))

      actor = %{id: Ash.UUID.generate(), role: :tenant_admin}

      # Read with tenant A context
      result = TenantPost |> Ash.read!(actor: actor, tenant: tenant_a)

      assert length(result) == 3
      result_ids = MapSet.new(result, & &1.id)
      expected_ids = MapSet.new(posts_a, & &1.id)
      assert result_ids == expected_ids
    end
  end

  describe "Check with ^tenant() scope" do
    test "tenant_admin can update posts in their tenant" do
      tenant_a = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_admin}

      post = generate(tenant_post(tenant_id: tenant_a))

      # Should be able to update with correct tenant context
      {:ok, updated} = Ash.update(post, %{title: "Updated"}, actor: actor, tenant: tenant_a)

      assert updated.title == "Updated"
    end

    test "tenant_admin cannot update posts in other tenants" do
      tenant_a = Ash.UUID.generate()
      tenant_b = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_admin}

      # Post belongs to tenant B
      post = generate(tenant_post(tenant_id: tenant_b))

      # Trying to update with tenant A context should fail
      result = Ash.update(post, %{title: "Hacked"}, actor: actor, tenant: tenant_a)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "tenant_admin can create posts in their tenant" do
      tenant_a = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_admin}

      # Create with correct tenant context
      {:ok, created} = Ash.create(
        TenantPost,
        %{title: "New Post", tenant_id: tenant_a},
        actor: actor,
        tenant: tenant_a
      )

      assert created.title == "New Post"
      assert created.tenant_id == tenant_a
    end

    test "tenant_admin cannot create posts for other tenants" do
      tenant_a = Ash.UUID.generate()
      tenant_b = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_admin}

      # Try to create post for tenant B while context is tenant A
      result = Ash.create(
        TenantPost,
        %{title: "Cross-tenant Post", tenant_id: tenant_b},
        actor: actor,
        tenant: tenant_a
      )

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "combined tenant + ownership scopes" do
    test "tenant_user can update own posts in their tenant" do
      tenant_a = Ash.UUID.generate()
      user_id = Ash.UUID.generate()
      actor = %{id: user_id, role: :tenant_user}

      # User's own post in their tenant
      post = generate(tenant_post(tenant_id: tenant_a, author_id: user_id))

      {:ok, updated} = Ash.update(post, %{title: "My Update"}, actor: actor, tenant: tenant_a)

      assert updated.title == "My Update"
    end

    test "tenant_user cannot update others' posts in their tenant" do
      tenant_a = Ash.UUID.generate()
      user_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()
      actor = %{id: user_id, role: :tenant_user}

      # Another user's post in the same tenant
      post = generate(tenant_post(tenant_id: tenant_a, author_id: other_id))

      result = Ash.update(post, %{title: "Not Mine"}, actor: actor, tenant: tenant_a)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "tenant_user cannot update own posts in other tenants" do
      tenant_a = Ash.UUID.generate()
      tenant_b = Ash.UUID.generate()
      user_id = Ash.UUID.generate()
      actor = %{id: user_id, role: :tenant_user}

      # User's own post but in a different tenant
      post = generate(tenant_post(tenant_id: tenant_b, author_id: user_id))

      # Try to update with tenant A context (wrong tenant)
      result = Ash.update(post, %{title: "Wrong Tenant"}, actor: actor, tenant: tenant_a)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "super_admin bypasses tenant restrictions" do
    test "super_admin can read all posts regardless of tenant" do
      tenant_a = Ash.UUID.generate()
      tenant_b = Ash.UUID.generate()

      post_a = generate(tenant_post(tenant_id: tenant_a))
      post_b = generate(tenant_post(tenant_id: tenant_b))

      actor = %{id: Ash.UUID.generate(), role: :super_admin}

      # Super admin can read all, even without tenant context
      posts = TenantPost |> Ash.read!(actor: actor)

      ids = MapSet.new(posts, & &1.id)
      assert post_a.id in ids
      assert post_b.id in ids
    end

    test "super_admin can update posts in any tenant" do
      tenant_b = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :super_admin}

      post = generate(tenant_post(tenant_id: tenant_b))

      {:ok, updated} = Ash.update(post, %{title: "Super Admin Update"}, actor: actor)

      assert updated.title == "Super Admin Update"
    end
  end
end

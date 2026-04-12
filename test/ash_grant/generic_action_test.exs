defmodule AshGrant.GenericActionTest do
  @moduledoc """
  Tests for generic action (type: :action) authorization.

  Generic actions use Ash.ActionInput instead of Ash.Query or Ash.Changeset.
  This module tests that AshGrant correctly handles ActionInput, specifically:

  1. Tenant extraction from action_input (issue #76)
  2. Permission checking for generic actions
  3. Deny-wins semantics for generic actions
  4. Ash.can? integration with ActionInput
  5. Mixed CRUD + generic actions on the same resource

  ## Permission Format for Generic Actions

  Generic actions must be authorized by their specific name, not by type wildcard.
  Unlike CRUD actions where `read*` matches all read-type actions, generic actions
  are individually unique (one might send email, another processes payment), so
  type-based wildcards don't apply.

  - `"service_request:*:ping:always"` — allows the specific "ping" action
  - `"service_request:*:*:always"` — allows ALL actions (admin wildcard)
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Test.ServiceRequest

  defp run_action(action, params, opts) do
    ServiceRequest
    |> Ash.ActionInput.for_action(action, params, opts)
    |> Ash.run_action()
  end

  # ============================================
  # 1. Basic Generic Action Authorization
  # ============================================

  describe "basic generic action authorization" do
    test "admin can run generic action" do
      actor = %{id: Ash.UUID.generate(), role: :admin}

      assert {:ok, "pong"} = run_action(:ping, %{}, actor: actor)
    end

    test "actor with explicit action-name permission can run generic action" do
      actor = custom_actor(permissions: ["service_request:*:ping:always"])

      assert {:ok, "pong"} = run_action(:ping, %{}, actor: actor)
    end

    test "actor with wildcard (*) permission can run generic action" do
      actor = custom_actor(permissions: ["service_request:*:*:always"])

      assert {:ok, "pong"} = run_action(:ping, %{}, actor: actor)
    end

    test "nil actor cannot run generic action" do
      assert {:error, %Ash.Error.Forbidden{}} = run_action(:ping, %{}, actor: nil)
    end

    test "actor without permission cannot run generic action" do
      actor = custom_actor(permissions: [])

      assert {:error, %Ash.Error.Forbidden{}} = run_action(:ping, %{}, actor: actor)
    end

    test "actor with only read permission cannot run generic action" do
      actor = custom_actor(permissions: ["service_request:*:read:always"])

      assert {:error, %Ash.Error.Forbidden{}} = run_action(:ping, %{}, actor: actor)
    end

    test "permission for different action name does not grant access" do
      # Has permission for check_status but not ping
      actor = custom_actor(permissions: ["service_request:*:check_status:always"])

      assert {:error, %Ash.Error.Forbidden{}} = run_action(:ping, %{}, actor: actor)
    end
  end

  # ============================================
  # 2. Tenant Extraction from ActionInput (#76)
  # ============================================

  describe "tenant extraction from action_input" do
    test "tenant_operator can run generic action with correct tenant" do
      tenant_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: tenant_id}

      assert {:ok, "pong"} = run_action(:ping, %{}, actor: actor, tenant: tenant_id)
    end

    test "tenant_operator cannot run generic action without tenant" do
      tenant_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: tenant_id}

      # No tenant passed — resolver returns [] because context.tenant is nil
      assert {:error, %Ash.Error.Forbidden{}} = run_action(:ping, %{}, actor: actor)
    end

    test "tenant_operator cannot run generic action with wrong tenant" do
      actor_tenant = Ash.UUID.generate()
      other_tenant = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: actor_tenant}

      # Pass different tenant — resolver returns [] because tenants don't match
      assert {:error, %Ash.Error.Forbidden{}} =
               run_action(:ping, %{}, actor: actor, tenant: other_tenant)
    end

    test "tenant is passed to resolver context for generic action with arguments" do
      tenant_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: tenant_id}

      assert {:ok, _} =
               run_action(
                 :check_status,
                 %{request_id: Ash.UUID.generate()},
                 actor: actor,
                 tenant: tenant_id
               )
    end
  end

  # ============================================
  # 3. Deny-Wins for Generic Actions
  # ============================================

  describe "deny-wins semantics for generic actions" do
    test "deny permission blocks generic action even with allow" do
      actor =
        custom_actor(
          permissions: [
            "service_request:*:ping:always",
            "!service_request:*:ping:always"
          ]
        )

      assert {:error, %Ash.Error.Forbidden{}} = run_action(:ping, %{}, actor: actor)
    end

    test "deny on specific action blocks only that action" do
      actor =
        custom_actor(
          permissions: [
            "service_request:*:*:always",
            "!service_request:*:ping:always"
          ]
        )

      assert {:error, %Ash.Error.Forbidden{}} = run_action(:ping, %{}, actor: actor)
    end

    test "deny on one action does not block another" do
      actor =
        custom_actor(
          permissions: [
            "service_request:*:ping:always",
            "service_request:*:check_status:always",
            "!service_request:*:check_status:always"
          ]
        )

      # ping is NOT denied
      assert {:ok, "pong"} = run_action(:ping, %{}, actor: actor)

      # check_status IS denied
      assert {:error, %Ash.Error.Forbidden{}} =
               run_action(:check_status, %{request_id: Ash.UUID.generate()}, actor: actor)
    end
  end

  # ============================================
  # 4. Ash.can? with Generic Actions
  # ============================================

  describe "Ash.can? with generic action input" do
    test "returns true for authorized actor" do
      actor = custom_actor(permissions: ["service_request:*:ping:always"])

      input = Ash.ActionInput.for_action(ServiceRequest, :ping, %{})
      assert {:ok, true} = Ash.can(input, actor)
    end

    test "returns false for unauthorized actor" do
      actor = custom_actor(permissions: [])

      input = Ash.ActionInput.for_action(ServiceRequest, :ping, %{})
      assert {:ok, false} = Ash.can(input, actor)
    end

    test "returns true for tenant_operator with correct tenant" do
      tenant_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: tenant_id}

      input = Ash.ActionInput.for_action(ServiceRequest, :ping, %{}, tenant: tenant_id)
      assert {:ok, true} = Ash.can(input, actor)
    end

    test "returns false for tenant_operator without tenant" do
      tenant_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: tenant_id}

      input = Ash.ActionInput.for_action(ServiceRequest, :ping, %{})
      assert {:ok, false} = Ash.can(input, actor)
    end
  end

  # ============================================
  # 5. CRUD Actions Still Work (Regression)
  # ============================================

  describe "CRUD actions on same resource are unaffected" do
    test "admin can create service request" do
      actor = %{id: Ash.UUID.generate(), role: :admin}

      {:ok, record} =
        Ash.create(ServiceRequest, %{title: "Test Request"}, actor: actor)

      assert record.title == "Test Request"
    end

    test "admin can read service requests" do
      actor = %{id: Ash.UUID.generate(), role: :admin}
      generate(service_request())

      records = Ash.read!(ServiceRequest, actor: actor)
      assert records != []
    end

    test "tenant_operator can create with correct tenant" do
      tenant_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: tenant_id}

      {:ok, record} =
        Ash.create(
          ServiceRequest,
          %{title: "Tenant Request", tenant_id: tenant_id},
          actor: actor,
          tenant: tenant_id
        )

      assert record.title == "Tenant Request"
    end

    test "tenant_operator cannot create without tenant context" do
      tenant_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), role: :tenant_operator, tenant_id: tenant_id}

      result =
        Ash.create(
          ServiceRequest,
          %{title: "No Tenant Request"},
          actor: actor
        )

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  # ============================================
  # 6. Generic Action with Arguments
  # ============================================

  describe "generic action with arguments" do
    test "authorized actor can run action with arguments" do
      actor = custom_actor(permissions: ["service_request:*:check_status:always"])
      request_id = Ash.UUID.generate()

      assert {:ok, status} =
               run_action(:check_status, %{request_id: request_id}, actor: actor)

      assert String.contains?(status, request_id)
    end

    test "unauthorized actor cannot run action with arguments" do
      actor = custom_actor(permissions: [])
      request_id = Ash.UUID.generate()

      assert {:error, %Ash.Error.Forbidden{}} =
               run_action(:check_status, %{request_id: request_id}, actor: actor)
    end
  end
end

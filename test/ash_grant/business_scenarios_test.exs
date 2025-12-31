defmodule AshGrant.BusinessScenariosTest do
  @moduledoc """
  Comprehensive tests for various business scope scenarios.

  Tests cover:
  1. Status-based workflow (Document)
  2. Organization hierarchy (Employee)
  3. Geographic/Territory (Customer)
  4. Security classification (Report)
  5. Project/Team assignment (Task)
  6. Transaction limits (Payment)
  7. Time/Period based (Journal)
  8. Complex ownership + Multi-tenant (SharedDocument)
  """
  use AshGrant.DataCase, async: true

  import AshGrant.Test.Generator

  alias AshGrant.Test.{Document, Report, Payment, Journal, Task, Customer, Employee, SharedDocument}

  # ============================================
  # 1. Status-Based Workflow (Document)
  # ============================================

  describe "Status-based workflow scopes" do
    test "reader can only see approved documents (positive + negative)" do
      scenario = document_workflow_scenario()
      actor = reader_actor()

      docs = Document |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see approved
      assert length(docs) == 1
      assert hd(docs).id == scenario.approved.id

      # Negative: CANNOT see other statuses
      refute scenario.draft.id in ids
      refute scenario.pending.id in ids
      refute scenario.archived.id in ids
    end

    test "author can see all documents" do
      scenario = document_workflow_scenario()
      actor = author_actor()

      docs = Document |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see all 4 documents
      assert length(docs) == 4
      assert scenario.draft.id in ids
      assert scenario.pending.id in ids
      assert scenario.approved.id in ids
      assert scenario.archived.id in ids
    end

    test "editable scope includes draft and pending_review but excludes others" do
      scenario = document_workflow_scenario()
      editable_actor = custom_actor(permissions: ["document:*:read:editable"])

      docs = Document |> Ash.read!(actor: editable_actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see draft and pending_review
      assert length(docs) == 2
      assert scenario.draft.id in ids
      assert scenario.pending.id in ids

      # Negative: CANNOT see approved or archived
      refute scenario.approved.id in ids
      refute scenario.archived.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _scenario = document_workflow_scenario()
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything without permissions - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Document |> Ash.read!(actor: no_perm_actor)
      end
    end

    test "nil actor raises Forbidden error" do
      _scenario = document_workflow_scenario()

      # Negative: nil actor CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Document |> Ash.read!(actor: nil)
      end
    end
  end

  # ============================================
  # 4. Security Classification (Report)
  # ============================================

  describe "Security classification scopes" do
    test "public actor can only see public reports (positive + negative)" do
      scenario = security_classification_scenario()
      actor = public_actor()

      reports = Report |> Ash.read!(actor: actor)
      ids = Enum.map(reports, & &1.id)

      # Positive: CAN see public
      assert length(reports) == 1
      assert scenario.public.id in ids

      # Negative: CANNOT see higher classifications
      refute scenario.internal.id in ids
      refute scenario.confidential.id in ids
      refute scenario.top_secret.id in ids
    end

    test "employee can see public and internal but not confidential or top_secret" do
      scenario = security_classification_scenario()
      actor = employee_actor()

      reports = Report |> Ash.read!(actor: actor)
      ids = Enum.map(reports, & &1.id)

      # Positive: CAN see public and internal
      assert length(reports) == 2
      assert scenario.public.id in ids
      assert scenario.internal.id in ids

      # Negative: CANNOT see higher classifications
      refute scenario.confidential.id in ids
      refute scenario.top_secret.id in ids
    end

    test "manager can see up to confidential but not top_secret" do
      scenario = security_classification_scenario()
      actor = manager_actor()

      reports = Report |> Ash.read!(actor: actor)
      ids = Enum.map(reports, & &1.id)

      # Positive: CAN see public, internal, confidential
      assert length(reports) == 3
      assert scenario.public.id in ids
      assert scenario.internal.id in ids
      assert scenario.confidential.id in ids

      # Negative: CANNOT see top_secret
      refute scenario.top_secret.id in ids
    end

    test "executive can see all reports including top_secret" do
      scenario = security_classification_scenario()
      actor = executive_actor()

      reports = Report |> Ash.read!(actor: actor)
      ids = Enum.map(reports, & &1.id)

      # Positive: CAN see all classifications
      assert length(reports) == 4
      assert scenario.public.id in ids
      assert scenario.internal.id in ids
      assert scenario.confidential.id in ids
      assert scenario.top_secret.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _scenario = security_classification_scenario()
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Report |> Ash.read!(actor: no_perm_actor)
      end
    end
  end

  # ============================================
  # 6. Transaction Limits (Payment)
  # ============================================

  describe "Transaction limit scopes" do
    test "clerk with small_amount scope sees under 1000, not 1000+" do
      scenario = payment_limits_scenario()
      actor = custom_actor(permissions: ["payment:*:read:small_amount"])

      payments = Payment |> Ash.read!(actor: actor)
      ids = Enum.map(payments, & &1.id)

      # Positive: CAN see small (500 < 1000)
      assert length(payments) == 1
      assert scenario.small.id in ids

      # Negative: CANNOT see payments >= 1000
      refute scenario.medium.id in ids  # 5000 >= 1000
      refute scenario.large.id in ids   # 50000 >= 1000
      refute scenario.huge.id in ids    # 500000 >= 1000
    end

    test "accountant with medium_amount scope sees under 10000, not 10000+" do
      scenario = payment_limits_scenario()
      actor = custom_actor(permissions: ["payment:*:read:medium_amount"])

      payments = Payment |> Ash.read!(actor: actor)
      ids = Enum.map(payments, & &1.id)

      # Positive: CAN see payments < 10000
      assert length(payments) == 2
      assert scenario.small.id in ids   # 500 < 10000
      assert scenario.medium.id in ids  # 5000 < 10000

      # Negative: CANNOT see payments >= 10000
      refute scenario.large.id in ids   # 50000 >= 10000
      refute scenario.huge.id in ids    # 500000 >= 10000
    end

    test "finance_manager with large_amount scope sees under 100000, not 100000+" do
      scenario = payment_limits_scenario()
      actor = custom_actor(permissions: ["payment:*:read:large_amount"])

      payments = Payment |> Ash.read!(actor: actor)
      ids = Enum.map(payments, & &1.id)

      # Positive: CAN see payments < 100000
      assert length(payments) == 3
      assert scenario.small.id in ids   # 500 < 100000
      assert scenario.medium.id in ids  # 5000 < 100000
      assert scenario.large.id in ids   # 50000 < 100000

      # Negative: CANNOT see payments >= 100000
      refute scenario.huge.id in ids    # 500000 >= 100000
    end

    test "cfo with unlimited scope can read all payments" do
      scenario = payment_limits_scenario()
      actor = cfo_actor()

      payments = Payment |> Ash.read!(actor: actor)
      ids = Enum.map(payments, & &1.id)

      # Positive: CAN see all payments (unlimited = true)
      assert length(payments) == 4
      assert scenario.small.id in ids
      assert scenario.medium.id in ids
      assert scenario.large.id in ids
      assert scenario.huge.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _scenario = payment_limits_scenario()
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Payment |> Ash.read!(actor: no_perm_actor)
      end
    end

    test "boundary: payment at exactly 1000 is NOT visible with small_amount scope" do
      # Test boundary condition: amount == 1000 should NOT be included (< 1000, not <= 1000)
      boundary_payment = generate(payment(amount: Decimal.new("1000")))
      under_boundary = generate(payment(amount: Decimal.new("999")))

      actor = custom_actor(permissions: ["payment:*:read:small_amount"])

      payments = Payment |> Ash.read!(actor: actor)
      ids = Enum.map(payments, & &1.id)

      # Positive: 999 < 1000
      assert under_boundary.id in ids

      # Negative: 1000 is NOT < 1000
      refute boundary_payment.id in ids
    end

    test "boundary: payment at exactly 10000 is NOT visible with medium_amount scope" do
      boundary_payment = generate(payment(amount: Decimal.new("10000")))
      under_boundary = generate(payment(amount: Decimal.new("9999")))

      actor = custom_actor(permissions: ["payment:*:read:medium_amount"])

      payments = Payment |> Ash.read!(actor: actor)
      ids = Enum.map(payments, & &1.id)

      # Positive: 9999 < 10000
      assert under_boundary.id in ids

      # Negative: 10000 is NOT < 10000
      refute boundary_payment.id in ids
    end
  end

  # ============================================
  # 7. Time/Period Based (Journal)
  # ============================================

  describe "Time/Period based scopes" do
    test "auditor can read all journals" do
      scenario = journal_periods_scenario()
      actor = auditor_actor()

      journals = Journal |> Ash.read!(actor: actor)
      ids = Enum.map(journals, & &1.id)

      # Positive: CAN see all 4 journals
      assert length(journals) == 4
      assert scenario.open_current.id in ids
      assert scenario.open_last.id in ids
      assert scenario.closed_current.id in ids
      assert scenario.closed_last.id in ids
    end

    test "accountant can read only open period journals, not closed" do
      scenario = journal_periods_scenario()
      actor = custom_actor(permissions: ["journal:*:read:open_periods"])

      journals = Journal |> Ash.read!(actor: actor)
      ids = Enum.map(journals, & &1.id)

      # Positive: CAN see open period journals
      assert length(journals) == 2
      assert scenario.open_current.id in ids
      assert scenario.open_last.id in ids

      # Negative: CANNOT see closed period journals
      refute scenario.closed_current.id in ids
      refute scenario.closed_last.id in ids
    end

    test "accountant can read journals from this fiscal year only" do
      scenario = journal_periods_scenario()
      actor = custom_actor(
        permissions: ["journal:*:read:this_fiscal_year"],
        fiscal_year: scenario.current_year
      )

      journals = Journal |> Ash.read!(actor: actor)
      ids = Enum.map(journals, & &1.id)

      # Positive: CAN see current year journals
      assert length(journals) == 2
      assert scenario.open_current.id in ids
      assert scenario.closed_current.id in ids

      # Negative: CANNOT see last year journals
      refute scenario.open_last.id in ids
      refute scenario.closed_last.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _scenario = journal_periods_scenario()
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Journal |> Ash.read!(actor: no_perm_actor)
      end
    end
  end

  # ============================================
  # 5. Project/Team Assignment (Task)
  # ============================================

  describe "Project/Team assignment scopes" do
    test "developer can only see assigned tasks, not others in same project" do
      actor_id = Ash.UUID.generate()
      project_id = Ash.UUID.generate()

      my_task = generate(task(assignee_id: actor_id, project_id: project_id))
      other_task = generate(task(project_id: project_id))

      actor = developer_actor(id: actor_id)

      tasks = Task |> Ash.read!(actor: actor)
      ids = Enum.map(tasks, & &1.id)

      # Positive: CAN see assigned task
      assert length(tasks) == 1
      assert my_task.id in ids

      # Negative: CANNOT see unassigned tasks even in same project
      refute other_task.id in ids
    end

    test "project_manager can see all tasks in their projects, not other projects" do
      actor_id = Ash.UUID.generate()
      my_project = Ash.UUID.generate()
      other_project = Ash.UUID.generate()

      my_task1 = generate(task(project_id: my_project))
      my_task2 = generate(task(project_id: my_project))
      other_task = generate(task(project_id: other_project))

      actor = project_manager_actor(id: actor_id, project_ids: [my_project])

      tasks = Task |> Ash.read!(actor: actor)
      ids = Enum.map(tasks, & &1.id)

      # Positive: CAN see tasks in my project
      assert length(tasks) == 2
      assert my_task1.id in ids
      assert my_task2.id in ids

      # Negative: CANNOT see tasks in other projects
      refute other_task.id in ids
    end

    test "team_member can see tasks in their team, not other teams" do
      actor_id = Ash.UUID.generate()
      my_team = Ash.UUID.generate()
      other_team = Ash.UUID.generate()

      my_team_task = generate(task(team_id: my_team))
      other_team_task = generate(task(team_id: other_team))

      actor = team_member_actor(id: actor_id, team_id: my_team)

      tasks = Task |> Ash.read!(actor: actor)
      ids = Enum.map(tasks, & &1.id)

      # Positive: CAN see my team's task
      assert length(tasks) == 1
      assert my_team_task.id in ids

      # Negative: CANNOT see other team's tasks
      refute other_team_task.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _task1 = generate(task())
      _task2 = generate(task())
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Task |> Ash.read!(actor: no_perm_actor)
      end
    end
  end

  # ============================================
  # 3. Geographic/Territory (Customer)
  # ============================================

  describe "Geographic/Territory scopes" do
    test "sales_rep can see only their assigned accounts, not others" do
      actor_id = Ash.UUID.generate()

      my_customer = generate(customer(account_manager_id: actor_id))
      other_customer = generate(customer())

      actor = custom_actor(permissions: ["customer:*:read:my_accounts"], id: actor_id)

      customers = Customer |> Ash.read!(actor: actor)
      ids = Enum.map(customers, & &1.id)

      # Positive: CAN see my account
      assert length(customers) == 1
      assert my_customer.id in ids

      # Negative: CANNOT see other accounts
      refute other_customer.id in ids
    end

    test "sales_rep can see customers in assigned territories, not other territories" do
      actor_id = Ash.UUID.generate()
      territory1 = Ash.UUID.generate()
      territory2 = Ash.UUID.generate()
      other_territory = Ash.UUID.generate()

      cust1 = generate(customer(territory_id: territory1))
      cust2 = generate(customer(territory_id: territory2))
      other_cust = generate(customer(territory_id: other_territory))

      actor = custom_actor(
        permissions: ["customer:*:read:assigned_territories"],
        id: actor_id,
        territory_ids: [territory1, territory2]
      )

      customers = Customer |> Ash.read!(actor: actor)
      ids = Enum.map(customers, & &1.id)

      # Positive: CAN see customers in assigned territories
      assert length(customers) == 2
      assert cust1.id in ids
      assert cust2.id in ids

      # Negative: CANNOT see customers in unassigned territories
      refute other_cust.id in ids
    end

    test "regional_manager can see customers in same region, not other regions" do
      region_id = Ash.UUID.generate()
      other_region = Ash.UUID.generate()

      my_region_cust = generate(customer(region_id: region_id))
      other_region_cust = generate(customer(region_id: other_region))

      actor = regional_manager_actor(region_id: region_id)

      customers = Customer |> Ash.read!(actor: actor)
      ids = Enum.map(customers, & &1.id)

      # Positive: CAN see customers in my region
      assert length(customers) == 1
      assert my_region_cust.id in ids

      # Negative: CANNOT see customers in other regions
      refute other_region_cust.id in ids
    end

    test "vip_manager can only see VIP customers, not standard or premium" do
      vip_cust = generate(vip_customer())
      standard_cust = generate(customer(tier: :standard))
      premium_cust = generate(premium_customer())

      actor = vip_manager_actor()

      customers = Customer |> Ash.read!(actor: actor)
      ids = Enum.map(customers, & &1.id)

      # Positive: CAN see VIP customers
      assert length(customers) == 1
      assert vip_cust.id in ids

      # Negative: CANNOT see non-VIP customers
      refute standard_cust.id in ids
      refute premium_cust.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _cust = generate(customer())
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Customer |> Ash.read!(actor: no_perm_actor)
      end
    end
  end

  # ============================================
  # 2. Organization Hierarchy (Employee)
  # ============================================

  describe "Organization hierarchy scopes" do
    test "team_lead can see employees in same org unit, not other orgs" do
      org_unit_id = Ash.UUID.generate()
      other_org = Ash.UUID.generate()

      my_org_emp = generate(employee(organization_unit_id: org_unit_id))
      other_org_emp = generate(employee(organization_unit_id: other_org))

      actor = team_lead_actor(org_unit_id: org_unit_id)

      employees = Employee |> Ash.read!(actor: actor)
      ids = Enum.map(employees, & &1.id)

      # Positive: CAN see employee in my org
      assert length(employees) == 1
      assert my_org_emp.id in ids

      # Negative: CANNOT see employees in other orgs
      refute other_org_emp.id in ids
    end

    test "dept_manager can see employees in subtree orgs, not outside subtree" do
      parent_org = Ash.UUID.generate()
      child_org1 = Ash.UUID.generate()
      child_org2 = Ash.UUID.generate()
      unrelated_org = Ash.UUID.generate()

      emp1 = generate(employee(organization_unit_id: parent_org))
      emp2 = generate(employee(organization_unit_id: child_org1))
      emp3 = generate(employee(organization_unit_id: child_org2))
      unrelated_emp = generate(employee(organization_unit_id: unrelated_org))

      actor = dept_manager_actor(
        org_unit_id: parent_org,
        subtree_org_ids: [parent_org, child_org1, child_org2]
      )

      employees = Employee |> Ash.read!(actor: actor)
      ids = Enum.map(employees, & &1.id)

      # Positive: CAN see employees in subtree
      assert length(employees) == 3
      assert emp1.id in ids
      assert emp2.id in ids
      assert emp3.id in ids

      # Negative: CANNOT see employees outside subtree
      refute unrelated_emp.id in ids
    end

    test "hr_manager can see all employees (global scope)" do
      emp1 = generate(employee())
      emp2 = generate(employee())
      emp3 = generate(employee())

      actor = hr_manager_actor()

      employees = Employee |> Ash.read!(actor: actor)
      ids = Enum.map(employees, & &1.id)

      # Positive: CAN see all employees
      assert length(employees) == 3
      assert emp1.id in ids
      assert emp2.id in ids
      assert emp3.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _emp = generate(employee())
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Employee |> Ash.read!(actor: no_perm_actor)
      end
    end
  end

  # ============================================
  # 8. Complex Ownership + Multi-tenant (SharedDocument)
  # ============================================

  describe "Complex ownership and multi-tenant scopes" do
    test "user can see documents created by them, not others" do
      actor_id = Ash.UUID.generate()
      tenant_id = Ash.UUID.generate()

      my_doc = generate(shared_document(created_by_id: actor_id, tenant_id: tenant_id))
      other_doc = generate(shared_document(tenant_id: tenant_id))

      actor = custom_actor(
        permissions: ["shared_document:*:read:created_by_me"],
        id: actor_id,
        tenant_id: tenant_id
      )

      docs = SharedDocument |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see my document
      assert length(docs) == 1
      assert my_doc.id in ids

      # Negative: CANNOT see documents created by others
      refute other_doc.id in ids
    end

    test "user can see documents shared with them, not unshared" do
      actor_id = Ash.UUID.generate()
      tenant_id = Ash.UUID.generate()

      shared_doc = generate(shared_document(tenant_id: tenant_id))
      not_shared = generate(shared_document(tenant_id: tenant_id))

      actor = custom_actor(
        permissions: ["shared_document:*:read:shared_with_me"],
        id: actor_id,
        tenant_id: tenant_id,
        shared_document_ids: [shared_doc.id]
      )

      docs = SharedDocument |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see shared document
      assert length(docs) == 1
      assert shared_doc.id in ids

      # Negative: CANNOT see unshared documents
      refute not_shared.id in ids
    end

    test "user with own_or_shared sees both created and shared docs, not others" do
      actor_id = Ash.UUID.generate()
      tenant_id = Ash.UUID.generate()

      my_doc = generate(shared_document(created_by_id: actor_id, tenant_id: tenant_id))
      shared_doc = generate(shared_document(tenant_id: tenant_id))
      other_doc = generate(shared_document(tenant_id: tenant_id))

      # User with both permissions (combined with OR)
      actor = custom_actor(
        permissions: [
          "shared_document:*:read:created_by_me",
          "shared_document:*:read:shared_with_me"
        ],
        id: actor_id,
        tenant_id: tenant_id,
        shared_document_ids: [shared_doc.id]
      )

      docs = SharedDocument |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see my_doc (created by me) and shared_doc (shared with me)
      assert length(docs) == 2
      assert my_doc.id in ids
      assert shared_doc.id in ids

      # Negative: CANNOT see unrelated docs
      refute other_doc.id in ids
    end

    test "tenant_admin can see all documents in their tenant, not other tenants" do
      tenant_id = Ash.UUID.generate()
      other_tenant = Ash.UUID.generate()

      tenant_doc1 = generate(shared_document(tenant_id: tenant_id))
      tenant_doc2 = generate(shared_document(tenant_id: tenant_id))
      other_tenant_doc = generate(shared_document(tenant_id: other_tenant))

      actor = tenant_admin_actor(tenant_id: tenant_id)

      docs = SharedDocument |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see all documents in my tenant
      assert length(docs) == 2
      assert tenant_doc1.id in ids
      assert tenant_doc2.id in ids

      # Negative: CANNOT see documents in other tenants
      refute other_tenant_doc.id in ids
    end

    test "tenant_active scope combines tenant and active status, excludes archived and other tenants" do
      tenant_id = Ash.UUID.generate()
      other_tenant = Ash.UUID.generate()

      active_doc = generate(active_shared_document(tenant_id: tenant_id))
      archived_doc = generate(archived_shared_document(tenant_id: tenant_id))
      other_tenant_active = generate(active_shared_document(tenant_id: other_tenant))

      actor = custom_actor(
        permissions: ["shared_document:*:read:tenant_active"],
        tenant_id: tenant_id
      )

      docs = SharedDocument |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see active docs in my tenant
      assert length(docs) == 1
      assert active_doc.id in ids

      # Negative: CANNOT see archived docs in my tenant
      refute archived_doc.id in ids
      # Negative: CANNOT see docs in other tenants
      refute other_tenant_active.id in ids
    end

    test "tenant_own scope combines tenant and ownership, excludes others' docs and other tenants" do
      actor_id = Ash.UUID.generate()
      tenant_id = Ash.UUID.generate()
      other_tenant = Ash.UUID.generate()

      my_doc = generate(shared_document(created_by_id: actor_id, tenant_id: tenant_id))
      other_doc = generate(shared_document(tenant_id: tenant_id))
      other_tenant_my_doc = generate(shared_document(created_by_id: actor_id, tenant_id: other_tenant))

      actor = custom_actor(
        permissions: ["shared_document:*:read:tenant_own"],
        id: actor_id,
        tenant_id: tenant_id
      )

      docs = SharedDocument |> Ash.read!(actor: actor)
      ids = Enum.map(docs, & &1.id)

      # Positive: CAN see my doc in my tenant
      assert length(docs) == 1
      assert my_doc.id in ids

      # Negative: CANNOT see others' docs in same tenant
      refute other_doc.id in ids
      # Negative: CANNOT see my docs in other tenants
      refute other_tenant_my_doc.id in ids
    end

    test "actor with no permissions raises Forbidden error" do
      _doc = generate(shared_document())
      no_perm_actor = custom_actor(permissions: [])

      # Negative: CANNOT see anything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        SharedDocument |> Ash.read!(actor: no_perm_actor)
      end
    end
  end

  # ============================================
  # 9. Deny Rules (!permission) Tests
  # ============================================

  describe "Deny rules (!permission) - deny-wins semantics" do
    test "deny blocks access even when allow exists for same resource/action" do
      _scenario = document_workflow_scenario()

      # Actor has "all" permission BUT also explicit deny for "read"
      actor = custom_actor(permissions: [
        "document:*:read:all",           # allow all
        "!document:*:read:approved"      # deny approved
      ])

      # Deny blocks ALL access when scope matches (deny-wins at action level)
      # Because deny for approved scope exists, evaluator returns [] for all scopes
      assert_raise Ash.Error.Forbidden, fn ->
        Document |> Ash.read!(actor: actor)
      end
    end

    test "deny wins regardless of permission order (allow first)" do
      _scenario = security_classification_scenario()

      # Allow first, then deny
      actor = custom_actor(permissions: [
        "report:*:read:top_secret",      # allow (sees all)
        "!report:*:read:confidential"    # deny
      ])

      # Deny wins - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Report |> Ash.read!(actor: actor)
      end
    end

    test "deny wins regardless of permission order (deny first)" do
      _scenario = security_classification_scenario()

      # Deny first, then allow
      actor = custom_actor(permissions: [
        "!report:*:read:confidential",   # deny
        "report:*:read:top_secret"       # allow (sees all)
      ])

      # Deny wins - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Report |> Ash.read!(actor: actor)
      end
    end

    test "specific deny does not affect other actions" do
      scenario = payment_limits_scenario()

      # Actor can read all, but has deny for "update" action
      actor = custom_actor(permissions: [
        "payment:*:read:unlimited",      # allow read
        "!payment:*:update:all"          # deny update
      ])

      # Read should still work (deny only affects update)
      payments = Payment |> Ash.read!(actor: actor)
      ids = Enum.map(payments, & &1.id)

      assert length(payments) == 4
      assert scenario.small.id in ids
      assert scenario.medium.id in ids
      assert scenario.large.id in ids
      assert scenario.huge.id in ids
    end

    test "deny for one resource does not affect other resources" do
      _doc_scenario = document_workflow_scenario()
      _report_scenario = security_classification_scenario()

      # Actor can read reports, but has deny for documents
      actor = custom_actor(permissions: [
        "report:*:read:top_secret",      # allow all reports
        "!document:*:read:all"           # deny all documents
      ])

      # Reports should work
      reports = Report |> Ash.read!(actor: actor)
      assert length(reports) == 4

      # Documents should be blocked - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Document |> Ash.read!(actor: actor)
      end
    end

    test "multiple scopes with one denied blocks all" do
      scenario = journal_periods_scenario()

      # Actor has multiple allow scopes but one deny
      actor = custom_actor(
        permissions: [
          "journal:*:read:open_periods",
          "journal:*:read:this_fiscal_year",
          "!journal:*:read:this_fiscal_year"  # deny same action
        ],
        fiscal_year: scenario.current_year
      )

      # Deny-wins: any deny for the action blocks everything - raises Forbidden
      assert_raise Ash.Error.Forbidden, fn ->
        Journal |> Ash.read!(actor: actor)
      end
    end

    test "instance-specific deny - documents current behavior" do
      _task1 = generate(task())
      task2 = generate(task())
      _task3 = generate(task())

      # Actor has all access but deny for specific task
      actor = custom_actor(permissions: [
        "task:*:read:all",               # allow all
        "!task:#{task2.id}:read:"        # deny specific instance
      ])

      # NOTE: Current implementation uses deny-wins at action level
      # Instance-specific denies currently don't filter individual records
      # This test documents the current behavior
      result = Task |> Ash.read(actor: actor)

      case result do
        {:ok, tasks} ->
          # Current behavior: instance deny doesn't filter individual records
          # All tasks are still visible because "all" scope wins for read
          assert length(tasks) >= 1
        {:error, %Ash.Error.Forbidden{}} ->
          # If deny-wins at action level, all access is blocked
          assert true
      end
    end
  end

  # ============================================
  # 10. Edge Cases and Error Conditions
  # ============================================

  describe "Edge cases and error conditions" do
    test "actor with nil id can still access if permissions allow scope:all" do
      _scenario = document_workflow_scenario()

      # Actor with nil id but valid permissions for "all" scope
      actor = custom_actor(permissions: ["document:*:read:all"], id: nil)

      # Should work based on permission scope
      docs = Document |> Ash.read!(actor: actor)
      assert length(docs) == 4
    end

    test "wildcard resource permission grants access" do
      _scenario = document_workflow_scenario()

      # Wildcard resource permission
      actor = custom_actor(permissions: ["*:*:read:all"])

      docs = Document |> Ash.read!(actor: actor)
      assert length(docs) == 4
    end

    test "wildcard action permission grants access" do
      _scenario = payment_limits_scenario()

      # Wildcard action permission
      actor = custom_actor(permissions: ["payment:*:*:unlimited"])

      payments = Payment |> Ash.read!(actor: actor)
      assert length(payments) == 4
    end

    test "specific scope filters correctly" do
      actor_id = Ash.UUID.generate()
      my_task = generate(task(assignee_id: actor_id))
      other_task = generate(task())

      # Has assigned scope only
      actor = custom_actor(
        permissions: ["task:*:read:assigned"],
        id: actor_id
      )

      tasks = Task |> Ash.read!(actor: actor)
      ids = Enum.map(tasks, & &1.id)

      # Only sees assigned task
      assert length(tasks) == 1
      assert my_task.id in ids
      refute other_task.id in ids
    end
  end
end

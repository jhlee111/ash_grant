defmodule AshGrant.Test.Generator do
  @moduledoc """
  Test data generators using Ash.Generator best practices.

  This module provides fixture generators for testing AshGrant's
  scope DSL functionality with various business scenarios.

  ## Usage

      import AshGrant.Test.Generator

      test "example" do
        post = generate(post())
        doc = generate(document(status: :approved))
        payments = generate_many(payment(amount: Decimal.new("500")), 5)
      end
  """

  use Ash.Generator

  alias AshGrant.Test.{
    Post, Comment, Document, Employee, Customer,
    Report, Task, Payment, Journal, SharedDocument, Article, TenantPost
  }

  # ============================================
  # Post Generators (Basic)
  # ============================================

  def post(opts \\ []) do
    seed_generator(
      %Post{
        id: Ash.UUID.generate(),
        title: sequence(:post_title, &"Post #{&1}"),
        body: "Test body content",
        status: :draft,
        author_id: Ash.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def published_post(opts \\ []), do: post(Keyword.put(opts, :status, :published))
  def draft_post(opts \\ []), do: post(Keyword.put(opts, :status, :draft))

  # ============================================
  # Article Generators (default_policies test)
  # ============================================

  def article(opts \\ []) do
    seed_generator(
      %Article{
        id: Ash.UUID.generate(),
        title: sequence(:article_title, &"Article #{&1}"),
        body: "Test article content",
        status: :draft,
        author_id: Ash.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def published_article(opts \\ []), do: article(Keyword.put(opts, :status, :published))
  def draft_article(opts \\ []), do: article(Keyword.put(opts, :status, :draft))

  # ============================================
  # Comment Generators
  # ============================================

  def comment(opts \\ []) do
    seed_generator(
      %Comment{
        id: Ash.UUID.generate(),
        body: sequence(:comment_body, &"Comment #{&1}"),
        user_id: Ash.UUID.generate(),
        post_id: Ash.UUID.generate(),
        inserted_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  # ============================================
  # 1. Document Generators (Status-based workflow)
  # ============================================

  def document(opts \\ []) do
    seed_generator(
      %Document{
        id: Ash.UUID.generate(),
        title: sequence(:doc_title, &"Document #{&1}"),
        content: "Document content",
        status: :draft,
        author_id: Ash.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def draft_document(opts \\ []), do: document(Keyword.put(opts, :status, :draft))
  def pending_document(opts \\ []), do: document(Keyword.put(opts, :status, :pending_review))
  def approved_document(opts \\ []), do: document(Keyword.put(opts, :status, :approved))
  def archived_document(opts \\ []), do: document(Keyword.put(opts, :status, :archived))

  # ============================================
  # 2. Employee Generators (Organization hierarchy)
  # ============================================

  def employee(opts \\ []) do
    seed_generator(
      %Employee{
        id: Ash.UUID.generate(),
        name: sequence(:emp_name, &"Employee #{&1}"),
        email: sequence(:emp_email, &"employee#{&1}@example.com"),
        organization_unit_id: Ash.UUID.generate(),
        manager_id: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  # ============================================
  # 3. Customer Generators (Geographic/Territory)
  # ============================================

  def customer(opts \\ []) do
    seed_generator(
      %Customer{
        id: Ash.UUID.generate(),
        name: sequence(:cust_name, &"Customer #{&1}"),
        region_id: Ash.UUID.generate(),
        country_code: "US",
        territory_id: Ash.UUID.generate(),
        account_manager_id: Ash.UUID.generate(),
        tier: :standard,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def vip_customer(opts \\ []), do: customer(Keyword.put(opts, :tier, :vip))
  def premium_customer(opts \\ []), do: customer(Keyword.put(opts, :tier, :premium))

  # ============================================
  # 4. Report Generators (Security classification)
  # ============================================

  def report(opts \\ []) do
    seed_generator(
      %Report{
        id: Ash.UUID.generate(),
        title: sequence(:report_title, &"Report #{&1}"),
        classification: :public,
        created_by_id: Ash.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def public_report(opts \\ []), do: report(Keyword.put(opts, :classification, :public))
  def internal_report(opts \\ []), do: report(Keyword.put(opts, :classification, :internal))
  def confidential_report(opts \\ []), do: report(Keyword.put(opts, :classification, :confidential))
  def top_secret_report(opts \\ []), do: report(Keyword.put(opts, :classification, :top_secret))

  # ============================================
  # 5. Task Generators (Project/Team)
  # ============================================

  def task(opts \\ []) do
    seed_generator(
      %Task{
        id: Ash.UUID.generate(),
        title: sequence(:task_title, &"Task #{&1}"),
        project_id: Ash.UUID.generate(),
        team_id: Ash.UUID.generate(),
        assignee_id: Ash.UUID.generate(),
        status: :open,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def open_task(opts \\ []), do: task(Keyword.put(opts, :status, :open))
  def in_progress_task(opts \\ []), do: task(Keyword.put(opts, :status, :in_progress))
  def completed_task(opts \\ []), do: task(Keyword.put(opts, :status, :completed))

  # ============================================
  # 6. Payment Generators (Transaction limits)
  # ============================================

  def payment(opts \\ []) do
    seed_generator(
      %Payment{
        id: Ash.UUID.generate(),
        description: sequence(:payment_desc, &"Payment #{&1}"),
        amount: Decimal.new("100"),
        status: :pending,
        approver_id: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def small_payment(opts \\ []), do: payment(Keyword.put(opts, :amount, Decimal.new("500")))
  def medium_payment(opts \\ []), do: payment(Keyword.put(opts, :amount, Decimal.new("5000")))
  def large_payment(opts \\ []), do: payment(Keyword.put(opts, :amount, Decimal.new("50000")))
  def huge_payment(opts \\ []), do: payment(Keyword.put(opts, :amount, Decimal.new("500000")))

  # ============================================
  # 7. Journal Generators (Time/Period based)
  # ============================================

  def journal(opts \\ []) do
    seed_generator(
      %Journal{
        id: Ash.UUID.generate(),
        description: sequence(:journal_desc, &"Journal Entry #{&1}"),
        amount: Decimal.new("1000"),
        period_id: Ash.UUID.generate(),
        period_status: :open,
        fiscal_year: Date.utc_today().year,
        created_by_id: Ash.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def open_period_journal(opts \\ []), do: journal(Keyword.put(opts, :period_status, :open))
  def closed_period_journal(opts \\ []), do: journal(Keyword.put(opts, :period_status, :closed))

  # ============================================
  # 8. SharedDocument Generators (Complex ownership + Multi-tenant)
  # ============================================

  def shared_document(opts \\ []) do
    seed_generator(
      %SharedDocument{
        id: Ash.UUID.generate(),
        title: sequence(:shared_doc_title, &"Shared Doc #{&1}"),
        created_by_id: Ash.UUID.generate(),
        tenant_id: Ash.UUID.generate(),
        status: :active,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def active_shared_document(opts \\ []), do: shared_document(Keyword.put(opts, :status, :active))
  def archived_shared_document(opts \\ []), do: shared_document(Keyword.put(opts, :status, :archived))

  # ============================================
  # 9. TenantPost Generators (Multi-tenancy with ^tenant())
  # ============================================

  def tenant_post(opts \\ []) do
    seed_generator(
      %TenantPost{
        id: Ash.UUID.generate(),
        title: sequence(:tenant_post_title, &"Tenant Post #{&1}"),
        body: "Tenant post content",
        status: :draft,
        author_id: Ash.UUID.generate(),
        tenant_id: Ash.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      overrides: opts
    )
  end

  def published_tenant_post(opts \\ []), do: tenant_post(Keyword.put(opts, :status, :published))
  def draft_tenant_post(opts \\ []), do: tenant_post(Keyword.put(opts, :status, :draft))

  # ============================================
  # Actor Generators
  # ============================================

  def admin_actor(opts \\ []) do
    id = Keyword.get(opts, :id, Ash.UUID.generate())
    Map.merge(%{id: id, role: :admin}, Map.new(opts))
  end

  def custom_actor(opts) do
    id = Keyword.get(opts, :id, Ash.UUID.generate())
    permissions = Keyword.get(opts, :permissions, [])
    extra = Keyword.drop(opts, [:id, :permissions])
    Map.merge(%{id: id, permissions: permissions}, Map.new(extra))
  end

  # Document actors
  def author_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :author}, Map.new(opts))
  def reviewer_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :reviewer}, Map.new(opts))
  def reader_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :reader}, Map.new(opts))

  # Employee actors
  def hr_manager_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :hr_manager}, Map.new(opts))
  def dept_manager_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :dept_manager}, Map.new(opts))
  def team_lead_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :team_lead}, Map.new(opts))

  # Customer actors
  def regional_manager_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :regional_manager}, Map.new(opts))
  def sales_rep_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :sales_rep}, Map.new(opts))
  def vip_manager_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :vip_manager}, Map.new(opts))

  # Report actors
  def executive_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :executive}, Map.new(opts))
  def manager_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :manager}, Map.new(opts))
  def employee_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :employee}, Map.new(opts))
  def public_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :public}, Map.new(opts))

  # Task actors
  def project_manager_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :project_manager}, Map.new(opts))
  def team_member_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :team_member}, Map.new(opts))
  def developer_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :developer}, Map.new(opts))

  # Payment actors
  def cfo_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :cfo}, Map.new(opts))
  def finance_manager_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :finance_manager}, Map.new(opts))
  def accountant_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :accountant}, Map.new(opts))
  def clerk_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :clerk}, Map.new(opts))

  # Journal actors
  def controller_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :controller}, Map.new(opts))
  def auditor_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :auditor}, Map.new(opts))

  # SharedDocument actors
  def tenant_admin_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :tenant_admin}, Map.new(opts))
  def user_actor(opts \\ []), do: Map.merge(%{id: Keyword.get(opts, :id, Ash.UUID.generate()), role: :user}, Map.new(opts))

  # ============================================
  # Scenario Helpers
  # ============================================

  @doc """
  Creates a complete document workflow scenario.
  Returns docs in each status for testing.
  """
  def document_workflow_scenario(opts \\ []) do
    author_id = Keyword.get(opts, :author_id, Ash.UUID.generate())

    %{
      draft: generate(draft_document(author_id: author_id)),
      pending: generate(pending_document(author_id: author_id)),
      approved: generate(approved_document(author_id: author_id)),
      archived: generate(archived_document(author_id: author_id)),
      author_id: author_id
    }
  end

  @doc """
  Creates reports at each classification level.
  """
  def security_classification_scenario(opts \\ []) do
    created_by_id = Keyword.get(opts, :created_by_id, Ash.UUID.generate())

    %{
      public: generate(public_report(created_by_id: created_by_id)),
      internal: generate(internal_report(created_by_id: created_by_id)),
      confidential: generate(confidential_report(created_by_id: created_by_id)),
      top_secret: generate(top_secret_report(created_by_id: created_by_id)),
      created_by_id: created_by_id
    }
  end

  @doc """
  Creates payments at different amount levels.
  """
  def payment_limits_scenario(_opts \\ []) do
    %{
      small: generate(small_payment()),       # 500 < 1000
      medium: generate(medium_payment()),     # 5000 < 10000
      large: generate(large_payment()),       # 50000 < 100000
      huge: generate(huge_payment())          # 500000 >= 100000
    }
  end

  @doc """
  Creates journals in open and closed periods.
  """
  def journal_periods_scenario(opts \\ []) do
    current_year = Date.utc_today().year
    last_year = current_year - 1

    open_period = Keyword.get(opts, :open_period_id, Ash.UUID.generate())
    closed_period = Keyword.get(opts, :closed_period_id, Ash.UUID.generate())

    %{
      open_current: generate(journal(period_id: open_period, period_status: :open, fiscal_year: current_year)),
      open_last: generate(journal(period_id: open_period, period_status: :open, fiscal_year: last_year)),
      closed_current: generate(journal(period_id: closed_period, period_status: :closed, fiscal_year: current_year)),
      closed_last: generate(journal(period_id: closed_period, period_status: :closed, fiscal_year: last_year)),
      open_period_id: open_period,
      closed_period_id: closed_period,
      current_year: current_year,
      last_year: last_year
    }
  end
end

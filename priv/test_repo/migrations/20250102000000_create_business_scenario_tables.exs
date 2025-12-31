defmodule AshGrant.TestRepo.Migrations.CreateBusinessScenarioTables do
  use Ecto.Migration

  def change do
    # 1. Document - Status-based workflow
    create table(:documents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :string, null: false
      add :content, :text
      add :status, :string, default: "draft"
      add :author_id, :uuid
      timestamps(type: :utc_datetime_usec)
    end

    create index(:documents, [:status])
    create index(:documents, [:author_id])

    # 2. Employee - Organization hierarchy
    create table(:employees, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :email, :string
      add :organization_unit_id, :uuid
      add :manager_id, :uuid
      timestamps(type: :utc_datetime_usec)
    end

    create index(:employees, [:organization_unit_id])

    # 3. Customer - Geographic/Territory
    create table(:customers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :region_id, :uuid
      add :country_code, :string
      add :territory_id, :uuid
      add :account_manager_id, :uuid
      add :tier, :string, default: "standard"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:customers, [:region_id])
    create index(:customers, [:territory_id])
    create index(:customers, [:account_manager_id])

    # 4. Report - Security classification
    create table(:reports, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :string, null: false
      add :classification, :string, default: "public"
      add :created_by_id, :uuid
      timestamps(type: :utc_datetime_usec)
    end

    create index(:reports, [:classification])

    # 5. Task - Project/Team assignment
    create table(:tasks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :string, null: false
      add :project_id, :uuid
      add :team_id, :uuid
      add :assignee_id, :uuid
      add :status, :string, default: "open"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:project_id])
    create index(:tasks, [:assignee_id])

    # 6. Payment - Transaction limits
    create table(:payments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :description, :string
      add :amount, :decimal, null: false
      add :status, :string, default: "pending"
      add :approver_id, :uuid
      timestamps(type: :utc_datetime_usec)
    end

    create index(:payments, [:status])

    # 7. Journal - Time/Period based
    create table(:journals, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :description, :string
      add :amount, :decimal
      add :period_id, :uuid
      add :period_status, :string, default: "open"
      add :fiscal_year, :integer
      add :created_by_id, :uuid
      timestamps(type: :utc_datetime_usec)
    end

    create index(:journals, [:period_id])
    create index(:journals, [:period_status])

    # 8. SharedDocument - Complex ownership with sharing
    create table(:shared_documents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :string, null: false
      add :created_by_id, :uuid
      add :tenant_id, :uuid
      add :status, :string, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:shared_documents, [:created_by_id])
    create index(:shared_documents, [:tenant_id])

    # Document shares junction table
    create table(:document_shares, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :document_id, references(:shared_documents, type: :uuid, on_delete: :delete_all)
      add :user_id, :uuid
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:document_shares, [:document_id, :user_id])
  end
end

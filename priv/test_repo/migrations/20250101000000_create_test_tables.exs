defmodule AshGrant.TestRepo.Migrations.CreateTestTables do
  use Ecto.Migration

  def change do
    create table(:posts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :string, null: false
      add :body, :text
      add :status, :string, default: "draft"
      add :author_id, :uuid

      timestamps(type: :utc_datetime_usec)
    end

    create index(:posts, [:author_id])
    create index(:posts, [:status])

    create table(:comments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :body, :string, null: false
      add :user_id, :uuid
      add :post_id, :uuid

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:comments, [:user_id])
    create index(:comments, [:post_id])
  end
end

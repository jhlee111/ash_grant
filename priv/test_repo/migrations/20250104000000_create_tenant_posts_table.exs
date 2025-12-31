defmodule AshGrant.TestRepo.Migrations.CreateTenantPostsTable do
  use Ecto.Migration

  def change do
    create table(:tenant_posts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :string, null: false
      add :body, :text
      add :status, :string, default: "draft"
      add :author_id, :uuid
      add :tenant_id, :uuid, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:tenant_posts, [:tenant_id])
    create index(:tenant_posts, [:author_id])
    create index(:tenant_posts, [:tenant_id, :author_id])
  end
end

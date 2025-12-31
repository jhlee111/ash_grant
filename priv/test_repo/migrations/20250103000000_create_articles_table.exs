defmodule AshGrant.TestRepo.Migrations.CreateArticlesTable do
  use Ecto.Migration

  def change do
    create table(:articles, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :title, :string, null: false
      add :body, :text
      add :status, :string, default: "draft"
      add :author_id, :uuid
      timestamps(type: :utc_datetime)
    end
  end
end

defmodule AshGrant.TestRepo.Migrations.CreateBulkTestTables do
  use Ecto.Migration

  def change do
    create table(:bulk_test_teams, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :name, :string, null: false

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create table(:bulk_test_memberships, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :user_id, :uuid, null: false
      add :team_id, references(:bulk_test_teams, type: :uuid, on_delete: :delete_all), null: false

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create table(:bulk_test_items, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :title, :string, null: false
      add :author_id, :uuid
      add :team_id, references(:bulk_test_teams, type: :uuid, on_delete: :nilify_all)

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end

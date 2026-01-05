defmodule AshGrant.TestRepo.Migrations.AddSharedDocsTable do
  use Ecto.Migration

  def change do
    create table(:shared_docs, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :title, :string, null: false
      add :owner_id, :string

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end

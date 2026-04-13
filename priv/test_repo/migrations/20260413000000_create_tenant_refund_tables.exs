defmodule AshGrant.TestRepo.Migrations.CreateTenantRefundTables do
  use Ecto.Migration

  def change do
    create table(:tenant_orders, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:center_id, :uuid, null: false)
      add(:tenant_id, :uuid, null: false)
    end

    create(index(:tenant_orders, [:tenant_id]))

    create table(:tenant_refunds, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:amount, :integer, null: false)
      add(:tenant_id, :uuid, null: false)

      add(
        :order_id,
        references(:tenant_orders, type: :uuid, on_delete: :delete_all),
        null: false
      )
    end

    create(index(:tenant_refunds, [:tenant_id]))
    create(index(:tenant_refunds, [:order_id]))
  end
end

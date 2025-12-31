ExUnit.start()

# Start the Repo for DB tests
{:ok, _} = AshGrant.TestRepo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AshGrant.TestRepo, :manual)

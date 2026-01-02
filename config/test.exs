import Config

# Use DATABASE_URL if available (for CI), otherwise use local defaults
if database_url = System.get_env("DATABASE_URL") do
  config :ash_grant, AshGrant.TestRepo,
    url: database_url <> (System.get_env("MIX_TEST_PARTITION") || ""),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
else
  config :ash_grant, AshGrant.TestRepo,
    username: System.get_env("POSTGRES_USER") || "johndev",
    password: System.get_env("POSTGRES_PASSWORD") || "",
    hostname: "localhost",
    database: "ash_grant_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
end

config :ash_grant,
  ecto_repos: [AshGrant.TestRepo],
  ash_domains: [AshGrant.Test.Domain]

config :logger, level: :warning

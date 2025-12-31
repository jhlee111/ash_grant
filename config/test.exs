import Config

config :ash_grant, AshGrant.TestRepo,
  username: "johndev",
  password: "",
  hostname: "localhost",
  database: "ash_grant_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :ash_grant,
  ecto_repos: [AshGrant.TestRepo],
  ash_domains: [AshGrant.Test.Domain]

config :logger, level: :warning

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

# Several property tests deliberately exercise the nil-action_type + type-wildcard
# combination to assert that type wildcards never match without a type. That is exactly
# the condition `AshGrant.IndeterminateMatch` signals, so the library default (`:warn`)
# would emit hundreds of correct-but-unwanted warnings across the suite. Default it off
# here; `indeterminate_match_test.exs` sets the mode explicitly per case.
config :ash_grant, indeterminate_type_wildcard: :off

config :logger, level: :warning

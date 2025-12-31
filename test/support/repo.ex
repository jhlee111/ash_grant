defmodule AshGrant.TestRepo do
  use AshPostgres.Repo,
    otp_app: :ash_grant,
    warn_on_missing_ash_functions?: false

  def installed_extensions do
    ["uuid-ossp", "citext"]
  end

  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end

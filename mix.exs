defmodule AshGrant.MixProject do
  use Mix.Project

  @version "0.14.0"
  @source_url "https://github.com/jhlee111/ash_grant"

  def project do
    [
      app: :ash_grant,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Hex
      description: "Permission-based authorization extension for Ash Framework",
      package: package(),

      # Docs
      name: "AshGrant",
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ash, ash_version("~> 3.19")},
      {:spark, spark_version("~> 2.0")},
      {:yaml_elixir, "~> 2.9", optional: true},

      # DB (test only)
      {:ash_postgres, "~> 2.0", only: :test},
      {:ecto_sql, "~> 3.10", only: :test},
      {:postgrex, "~> 0.17", only: :test},
      {:simple_sat, "~> 0.1", only: :test},

      # Dev/Test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: "ash_grant",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Home"],
        "guides/getting-started.md": [title: "Getting Started"],
        "guides/authorization-patterns.md": [title: "RBAC / ABAC / ReBAC / More"],
        "guides/permissions.md": [title: "Permissions"],
        "guides/scopes.md": [title: "Scopes"],
        "guides/field-level-permissions.md": [title: "Field-Level Permissions"],
        "guides/checks-and-policies.md": [title: "Checks & Policies"],
        "guides/debugging-and-introspection.md": [title: "Debugging & Introspection"],
        "guides/policy-testing.md": [title: "Policy Testing"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ]
    ]
  end

  defp ash_version(default_version) do
    case System.get_env("ASH_VERSION") do
      nil -> default_version
      "local" -> [path: "../ash", override: true]
      "main" -> [git: "https://github.com/ash-project/ash.git", override: true]
      version -> "~> #{version}"
    end
  end

  defp spark_version(default_version) do
    case System.get_env("SPARK_VERSION") do
      nil -> default_version
      "local" -> [path: "../spark", override: true]
      "main" -> [git: "https://github.com/ash-project/spark.git", override: true]
      version -> "~> #{version}"
    end
  end
end

defmodule Mix.Tasks.AshGrant.CheckPermissions do
  @moduledoc """
  Checks stored permission strings against the application's resources.

  Permission strings live in your roles table, seeds or migrations — the compiler
  never sees them. This task runs `AshGrant.PermissionValidation.check_all/2`
  over a file of them, so a pipeline can refuse a release whose code no longer
  matches the strings it will meet (a renamed action, scope or field group, or a
  plain typo).

  ## Usage

      mix ash_grant.check_permissions FILE [options]

  `FILE` is either:

    * a `.json` file holding an array of permission strings, or an object whose
      values are arrays of them (`{"editor": ["post:*:read:always"]}`) — the keys
      are shown next to each finding; or
    * any other file, read as one permission per line. Blank lines and lines
      starting with `#` are skipped.

  Pass `-` to read a newline list from standard input:

      psql -At -c "select unnest(permissions) from roles" | mix ash_grant.check_permissions -

  ## Options

    * `--otp-app` - Check against the resources in this application's
      `:ash_domains`. Without it, every AshGrant resource in the started
      applications' `:ash_domains` is used.
    * `--format`  - `text` (default) or `json`.

  ## Exit codes

    * 0 - No issue of severity `:error`. Warnings are printed but do not fail.
    * 1 - At least one `:error`.
    * 2 - Usage error (missing file, unreadable input, invalid option).
  """

  use Mix.Task

  alias AshGrant.PermissionValidation

  @shortdoc "Check stored permission strings against the application's resources"

  @switches [otp_app: :string, format: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case run_cli(args) do
      {:ok, output, 0} ->
        Mix.shell().info(output)

      {:error, output, exit_code} ->
        Mix.shell().error(output)
        System.at_exit(fn _ -> exit({:shutdown, exit_code}) end)
    end
  end

  @doc """
  Pure entry point used by both `run/1` and the test suite.

  Returns `{:ok | :error, output_string, exit_code}`. Accepts a `:resources`
  option in `check_opts` so tests can pin the resources without an OTP app.
  """
  @spec run_cli([String.t()], keyword()) ::
          {:ok, String.t(), 0} | {:error, String.t(), 1 | 2}
  def run_cli(args, check_opts \\ []) do
    with {:ok, opts, path} <- parse_args(args),
         {:ok, format} <- parse_format(opts),
         {:ok, entries} <- read_entries(path) do
      check_opts = Keyword.merge(otp_app_opts(opts), check_opts)

      if PermissionValidation.ResourceIndex.build(check_opts) == [] do
        no_resources(opts)
      else
        check_entries(entries, check_opts, format)
      end
    end
  end

  # Without this, a wrong --otp-app would report every string in the file as an
  # unknown resource, burying the one thing that is actually wrong.
  defp no_resources(opts) do
    where =
      case Keyword.get(opts, :otp_app) do
        nil -> "the started applications' :ash_domains"
        app -> ":#{app}'s :ash_domains"
      end

    {:error, "No AshGrant resources found in #{where}. Nothing to check against.", 2}
  end

  defp check_entries(entries, check_opts, format) do
    results =
      entries
      |> Enum.map(&elem(&1, 1))
      |> PermissionValidation.check_all(check_opts)
      |> Enum.zip_with(entries, fn {permission, issues}, {label, _} ->
        %{label: label, permission: permission, issues: issues}
      end)

    report(results, format)
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [path], []} ->
        {:ok, opts, path}

      {_opts, _rest, [_ | _] = invalid} ->
        {:error, "Invalid options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}", 2}

      {_opts, [], []} ->
        {:error,
         "Usage: mix ash_grant.check_permissions FILE [--otp-app APP] [--format text|json]", 2}

      {_opts, _many, []} ->
        {:error, "Expected exactly one FILE", 2}
    end
  end

  defp parse_format(opts) do
    case Keyword.get(opts, :format, "text") do
      "text" -> {:ok, :text}
      "json" -> {:ok, :json}
      other -> {:error, "Invalid --format: #{other} (expected text or json)", 2}
    end
  end

  defp otp_app_opts(opts) do
    case Keyword.get(opts, :otp_app) do
      nil -> []
      app -> [otp_app: String.to_atom(app)]
    end
  end

  # -- input ------------------------------------------------------------------

  defp read_entries("-"), do: {:ok, :stdio |> IO.read(:eof) |> to_string() |> lines()}

  defp read_entries(path) do
    case File.read(path) do
      {:ok, content} ->
        if Path.extname(path) == ".json", do: json(content, path), else: {:ok, lines(content)}

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{:file.format_error(reason)}", 2}
    end
  end

  defp lines(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&{nil, &1})
  end

  defp json(content, path) do
    case Jason.decode(content) do
      {:ok, list} when is_list(list) ->
        strings(list, nil, path)

      {:ok, %{} = map} ->
        labelled_strings(map, path)

      {:ok, _other} ->
        {:error, "#{path}: expected a JSON array of strings, or an object of such arrays", 2}

      {:error, error} ->
        {:error, "#{path}: invalid JSON (#{Exception.message(error)})", 2}
    end
  end

  defp labelled_strings(map, path) do
    map
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {label, value}, {:ok, acc} ->
      case strings(List.wrap(value), label, path) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        error -> {:halt, error}
      end
    end)
  end

  defp strings(list, label, path) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, Enum.map(list, &{label, &1})}
    else
      {:error, "#{path}: expected a JSON array of strings, or an object of such arrays", 2}
    end
  end

  # -- output -----------------------------------------------------------------

  defp report(results, format) do
    issues = Enum.flat_map(results, & &1.issues)
    failed? = PermissionValidation.errors?(issues)
    output = render(results, issues, format)

    if failed?, do: {:error, output, 1}, else: {:ok, output, 0}
  end

  defp render(results, issues, :json) do
    Jason.encode!(%{
      checked: length(results),
      errors: count(issues, :error),
      warnings: count(issues, :warning),
      results:
        for %{issues: [_ | _]} = result <- results do
          %{
            label: result.label,
            permission: result.permission,
            issues:
              Enum.map(result.issues, fn issue ->
                %{
                  code: issue.code,
                  severity: issue.severity,
                  segment: issue.segment,
                  message: issue.message,
                  resources: Enum.map(issue.resources, &inspect/1)
                }
              end)
          }
        end
    })
  end

  defp render(results, issues, :text) do
    findings =
      for %{issues: [_ | _]} = result <- results do
        label = if result.label, do: " (#{result.label})", else: ""

        [result.permission <> label | Enum.map(result.issues, &"  #{&1.severity}: #{&1.message}")]
        |> Enum.join("\n")
      end

    summary =
      "Checked #{length(results)} permission(s): " <>
        "#{count(issues, :error)} error(s), #{count(issues, :warning)} warning(s)."

    Enum.join(findings ++ [summary], "\n\n")
  end

  defp count(issues, severity), do: Enum.count(issues, &(&1.severity == severity))
end

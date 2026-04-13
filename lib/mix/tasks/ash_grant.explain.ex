defmodule Mix.Tasks.AshGrant.Explain do
  @moduledoc """
  Explains an AshGrant access decision from the command line.

  Uses `AshGrant.Introspect.explain_by_identifier/1` under the hood, so
  the resource's permission resolver must implement the optional
  `load_actor/1` callback. If it doesn't, you'll see
  `actor_loader_not_implemented`.

  ## Usage

      mix ash_grant.explain --actor USER_ID --resource RESOURCE_KEY --action ACTION [options]

  ## Options

    * `--actor`    - Required. Actor identifier (passed to `load_actor/1`).
    * `--resource` - Required. Resource key (matches `resource_name`).
    * `--action`   - Required. Action name (atom).
    * `--format`   - `text` (default) or `json`.
    * `--context`  - Optional JSON object forwarded to the resolver.

  ## Examples

      # Human-readable
      mix ash_grant.explain --actor user_123 --resource post --action read

      # Machine-readable for CI/LLM pipelines
      mix ash_grant.explain --actor user_123 --resource post --action read --format json

      # With context
      mix ash_grant.explain --actor user_123 --resource post --action read \\
        --context '{"reference_date":"2024-01-01"}'

  ## Exit codes

    * 0 - Explanation produced (regardless of allow/deny).
    * 1 - Lookup failure (unknown resource, actor not found, missing loader).
    * 2 - Usage error (missing required option, invalid value).
  """

  use Mix.Task

  @shortdoc "Explain an AshGrant access decision for an actor/resource/action"

  @switches [
    actor: :string,
    resource: :string,
    action: :string,
    format: :string,
    context: :string
  ]

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

  Returns `{:ok | :error, output_string, exit_code}` so callers can
  inspect the task's behaviour without intercepting Mix shell output.
  """
  @spec run_cli([String.t()]) ::
          {:ok, String.t(), 0} | {:error, String.t(), 1 | 2}
  def run_cli(args) do
    with {:ok, opts} <- parse_args(args),
         {:ok, call_opts} <- build_call_opts(opts),
         {:ok, format} <- parse_format(opts) do
      call_and_format(call_opts, format)
    end
  end

  defp parse_args(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid == [] do
      {:ok, opts}
    else
      names = Enum.map_join(invalid, ", ", fn {name, _} -> name end)
      {:error, "Invalid options: #{names}", 2}
    end
  end

  defp build_call_opts(opts) do
    with {:ok, actor_id} <- fetch_required(opts, :actor),
         {:ok, resource_key} <- fetch_required(opts, :resource),
         {:ok, action_str} <- fetch_required(opts, :action),
         {:ok, context} <- parse_context(opts) do
      action = String.to_atom(action_str)

      {:ok,
       [
         actor_id: actor_id,
         resource_key: resource_key,
         action: action,
         context: context
       ]}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when value != "" -> {:ok, value}
      _ -> {:error, "Missing required option: --#{key}", 2}
    end
  end

  defp parse_context(opts) do
    case Keyword.get(opts, :context) do
      nil ->
        {:ok, %{}}

      json when is_binary(json) ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, %{} = map} ->
            {:ok, map}

          {:ok, _other} ->
            {:error, "--context must decode to a JSON object", 2}

          {:error, err} ->
            {:error, "--context is not valid JSON: #{inspect(err)}", 2}
        end
    end
  end

  defp parse_format(opts) do
    case Keyword.get(opts, :format, "text") do
      "text" -> {:ok, :text}
      "json" -> {:ok, :json}
      other -> {:error, "Unknown --format value: #{inspect(other)}", 2}
    end
  end

  defp call_and_format(call_opts, format) do
    case AshGrant.Introspect.explain_by_identifier(call_opts) do
      {:ok, explanation} ->
        {:ok, format_explanation(explanation, format), 0}

      {:error, reason} ->
        {:error, format_error(reason), 1}
    end
  end

  defp format_explanation(explanation, :json) do
    Jason.encode!(explanation)
  end

  defp format_explanation(explanation, :text) do
    decision = explanation.decision |> to_string() |> String.upcase()
    resource = inspect(explanation.resource)

    lines = [
      "Decision:     #{decision}",
      "Resource:     #{resource}",
      "Action:       #{inspect(explanation.action)}",
      "Actor:        #{inspect(explanation.actor)}",
      "Reason code:  #{explanation.reason_code}",
      "Summary:      #{explanation.summary}"
    ]

    lines =
      if is_binary(explanation.scope_filter_string) do
        lines ++ ["Scope filter: #{explanation.scope_filter_string}"]
      else
        lines
      end

    matched =
      case explanation.matching_permissions do
        [] -> ["(no matching permissions)"]
        perms -> Enum.map(perms, &"  - #{inspect(&1)}")
      end

    Enum.join(lines ++ ["Matching permissions:" | matched], "\n")
  end

  defp format_error(:unknown_resource),
    do: "unknown_resource — no resource matched the given --resource key"

  defp format_error(:actor_not_found),
    do: "actor_not_found — resolver.load_actor/1 returned :error for the given --actor"

  defp format_error(:actor_loader_not_implemented),
    do:
      "actor_loader_not_implemented — the resource's permission resolver does not implement load_actor/1"

  defp format_error(other), do: "error: #{inspect(other)}"
end

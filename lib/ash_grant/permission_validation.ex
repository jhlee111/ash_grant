defmodule AshGrant.PermissionValidation do
  @moduledoc """
  Validates resolved actor permissions and signals invalid combinations.

  Currently enforces one rule (issue #117): a permission that is a **deny**
  (`!` prefix) must not carry a **field_group** (5th part). A field-group deny is
  invalid because field-group access is positive-only — column restrictions
  belong in the resource's `field_group` definition (`inherits`/`except`/`mask`),
  and a deny carrying a field_group currently over-denies the *entire* action
  (fail-closed) rather than the named group.

  The validator never changes the authorization outcome; it only *signals* the
  invalid permission according to the configured mode:

    * `:off`    — do nothing
    * `:warn`   — emit a `Logger.warning` (deduplicated per process)
    * `:strict` — raise `AshGrant.PermissionValidation.InvalidPermissionError`

  The mode is configured per resource via the `field_group_permissions` option in
  the `ash_grant` DSL block (default `:warn`).
  """

  require Logger

  alias AshGrant.Permission

  defmodule InvalidPermissionError do
    @moduledoc """
    Raised in `:strict` mode when an actor's permissions contain a deny rule that
    carries a field_group — an invalid combination. See `AshGrant.PermissionValidation`.
    """
    defexception [:message]
  end

  @type mode :: :off | :warn | :strict

  @doc """
  Validates `permissions` and signals any invalid deny+field_group entries per `mode`.

  Accepts the same permission representations the resolver may return (strings,
  `%AshGrant.Permission{}` structs, `%AshGrant.PermissionInput{}`, or
  `Permissionable` maps). Always returns `:ok`; raises `InvalidPermissionError`
  only in `:strict` mode when an offender is present.

  ## Options

    * `:resource` — the resource module, included in the message for context.
  """
  @spec validate(list(), mode(), keyword()) :: :ok
  def validate(permissions, mode, opts \\ [])

  def validate(_permissions, :off, _opts), do: :ok

  def validate(permissions, mode, opts) when mode in [:warn, :strict] do
    case offenders(permissions) do
      [] -> :ok
      offenders -> signal(offenders, mode, opts)
    end
  end

  defp offenders(permissions) do
    permissions
    |> AshGrant.Evaluator.normalize_permissions()
    |> Enum.filter(fn
      %Permission{} = p -> p.deny and not is_nil(p.field_group)
      _ -> false
    end)
  end

  defp signal(offenders, :strict, opts) do
    raise InvalidPermissionError, message: message(offenders, opts)
  end

  defp signal(offenders, :warn, opts) do
    key = {opts[:resource], offenders |> offender_strings() |> Enum.sort()}

    unless warned?(key) do
      mark_warned(key)
      Logger.warning(message(offenders, opts))
    end

    :ok
  end

  defp message(offenders, opts) do
    strings = offender_strings(offenders)
    on = if resource = opts[:resource], do: " on #{inspect(resource)}", else: ""

    "AshGrant: deny rules cannot carry a field_group (5th part)#{on}. " <>
      "These permissions are invalid and currently over-deny the entire action " <>
      "(fail-closed): #{inspect(strings)}. Field-group access is positive-only — " <>
      "express column restrictions in the resource's field_group definition " <>
      "(inherits/except/mask) and grant groups positively."
  end

  defp offender_strings(offenders), do: Enum.map(offenders, &Permission.to_string/1)

  # Per-process dedup so repeated checks within one request log at most once per
  # {resource, offender-set}. The dedup set lives in the process dictionary; in a
  # typical request-per-process model it dies with the request. Offenders are a
  # misconfiguration and expected to be rare, so the set stays small.
  defp warned?(key), do: MapSet.member?(warned_set(), key)

  defp mark_warned(key), do: Process.put(__MODULE__, MapSet.put(warned_set(), key))

  defp warned_set, do: Process.get(__MODULE__, MapSet.new())
end

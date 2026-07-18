defmodule AshGrant.IndeterminateMatch do
  @moduledoc """
  Signals authorization answers that could not actually be determined (issue #126).

  A type wildcard (`"@read"`, or the deprecated `"read*"`) matches on the Ash action
  **type**, so it can only be evaluated when an `action_type` is supplied. Every
  `AshGrant.Evaluator` entry point defaults `action_type` to `nil`, and with `nil` a
  type wildcard silently fails to match. The result is a two-layer asymmetry — same
  actor, same grant, opposite answers:

      actor = %{permissions: ["document:*:@read:always"]}

      # Takes the resource module, so it resolves the action type:
      AshGrant.Introspect.can?(Document, :read, actor)
      # => {:allow, ...}

      # Takes a resource string, so it cannot — and answers anyway:
      AshGrant.Evaluator.has_access?(actor.permissions, "document", "read")
      # => false

  That `false` is not "does not match", it is "could not tell" wearing "does not
  match" as a disguise — indistinguishable from a legitimate deny, which is what makes
  it expensive to debug. In practice it forces defensive `read*` + literal `read` grant
  pairs, and dropping the literal silently kills the feature it gated.

  This module detects the case and signals it **without changing the outcome**:

    * `:off`    — do nothing
    * `:warn`   — emit a `Logger.warning` (deduplicated per process)
    * `:strict` — raise `AshGrant.IndeterminateMatch.IndeterminateMatchError`

  Configure globally (the affected entry points take a resource *string*, so there is
  no resource module to read a DSL option from):

      config :ash_grant, indeterminate_type_wildcard: :strict

  Default is `:warn`.

  ## How it decides — recompute and compare

  Detection is **sound**: it never flags a call whose answer the skipped wildcards could
  not have changed, because false positives would make `:strict` unusable. Rather than
  reason about each function's return shape, `guard/6` recomputes the same result twice:

    * once as the caller did — every type wildcard treated as non-matching;
    * once with those wildcards **forced to match**.

  If the two results are equal, the wildcards were irrelevant (the answer is the same
  whichever way they would have resolved) and nothing is signalled — this correctly
  stays silent for a defensive wildcard-plus-literal pair, a scope-less wildcard that
  contributes nothing, or a query already settled by a concrete deny. If they differ,
  the true answer depends on a type the call did not supply, and it is reported.

  Forcing all wildcards at once can, in rare mixed allow/deny cases, mask a difference
  (a false *negative*); it never invents one (no false *positive*).

  Only RBAC grants (`instance_id == "*"`) are forced. A type wildcard on an instance
  permission is dead outright — `AshGrant.Permission.diagnostics/1` reports that — so it
  is treated as non-matching in both passes, never as indeterminate.

  ## Fixing a reported call

  Supply the action type, or use an API that resolves it for you:

      # Resolves the type from the resource module:
      AshGrant.Introspect.can?(MyApp.Document, :read, actor)

      # Or pass it explicitly:
      AshGrant.Evaluator.has_access?(perms, "document", "list_published", :read)
  """

  require Logger

  alias AshGrant.Permission

  defmodule IndeterminateMatchError do
    @moduledoc """
    Raised in `:strict` mode when an authorization question could not be answered
    because a type wildcard was evaluated without an `action_type`.
    See `AshGrant.IndeterminateMatch`.
    """
    defexception [:message]
  end

  @type mode :: :off | :warn | :strict

  @typedoc """
  Recomputes an entry point's result using the given per-permission match predicate.

  The predicate replaces every `Permission.matches?/4` (or `matches_action?/3`) call in
  the function body, so `guard/6` can run the body a second time with wildcards forced.
  """
  @type compute :: ((Permission.t() -> boolean()) -> term())

  @default_mode :warn

  @doc """
  Returns the configured mode (default `:warn`).
  """
  @spec mode() :: mode()
  def mode do
    Application.get_env(:ash_grant, :indeterminate_type_wildcard, @default_mode)
  end

  @doc """
  Runs `compute` with `match_fn`, returning its result and signalling if a forced
  recompute would differ.

  Never alters the outcome — the normal result is always what comes back. Raises
  `IndeterminateMatchError` only in `:strict` mode, and only when forcing the skipped
  type wildcards to match would change the result.
  """
  @spec guard(
          compute(),
          (Permission.t() -> boolean()),
          [Permission.t()],
          String.t(),
          String.t(),
          atom() | nil
        ) ::
          term()
  # A supplied action_type means every wildcard was evaluated — nothing to force.
  def guard(compute, match_fn, _permissions, _resource, _action, action_type)
      when not is_nil(action_type) do
    compute.(match_fn)
  end

  def guard(compute, match_fn, permissions, resource, action, nil) do
    normal = compute.(match_fn)
    detect(normal, compute, match_fn, permissions, resource, action, mode())
  end

  defp detect(normal, _compute, _match_fn, _permissions, _resource, _action, :off), do: normal

  defp detect(normal, compute, match_fn, permissions, resource, action, active_mode) do
    case wildcards(permissions, resource) do
      [] ->
        normal

      offenders ->
        forced = compute.(forced_match_fn(match_fn, offenders))

        if normal == forced,
          do: normal,
          else: report(normal, offenders, resource, action, active_mode)
    end
  end

  # The normal predicate, but every skipped RBAC type wildcard is treated as matching.
  defp forced_match_fn(match_fn, offenders) do
    forced = MapSet.new(offenders)
    fn perm -> MapSet.member?(forced, perm) or match_fn.(perm) end
  end

  # RBAC type-wildcard grants for this resource — the permissions whose match could not
  # be determined without an action_type. Instance permissions are excluded: a type
  # wildcard there is dead (see diagnostics/1), not indeterminate.
  defp wildcards(permissions, resource) do
    Enum.filter(permissions, fn
      %Permission{instance_id: "*"} = perm ->
        Permission.type_wildcard?(perm) and Permission.matches_resource?(perm.resource, resource)

      %Permission{} ->
        false
    end)
  end

  defp report(_normal, offenders, resource, action, :strict) do
    raise IndeterminateMatchError, message: message(offenders, resource, action)
  end

  defp report(normal, offenders, resource, action, :warn) do
    key = {resource, action, offenders |> strings() |> Enum.sort()}

    unless warned?(key) do
      mark_warned(key)
      Logger.warning(message(offenders, resource, action))
    end

    normal
  end

  defp message(offenders, resource, action) do
    reasons =
      []
      |> maybe_reason(
        offenders,
        &(not Permission.deny?(&1)),
        "a grant that may allow it was skipped"
      )
      |> maybe_reason(
        offenders,
        &Permission.deny?/1,
        "a deny rule that may forbid it was skipped"
      )
      |> Enum.join("; and ")

    "AshGrant: indeterminate authorization result for #{resource}:#{action}. " <>
      "The call supplied no action_type, so these type wildcards could not be evaluated " <>
      "and were treated as non-matching: #{inspect(strings(offenders))}. " <>
      "#{reasons} — the result may be wrong. Supply an action_type (e.g. " <>
      "AshGrant.Evaluator.has_access?(perms, #{inspect(resource)}, #{inspect(action)}, " <>
      ":read)), or use AshGrant.Introspect.can?/4, which resolves the action type from " <>
      "the resource module. See AshGrant.IndeterminateMatch."
  end

  defp maybe_reason(reasons, offenders, pred, text) do
    if Enum.any?(offenders, pred), do: reasons ++ [text], else: reasons
  end

  defp strings(offenders), do: offenders |> Enum.map(&Permission.to_string/1) |> Enum.uniq()

  # Per-process dedup, mirroring AshGrant.PermissionValidation: repeated checks within
  # one request log at most once per {resource, action, wildcard-set}. The set lives in
  # the process dictionary and dies with the request.
  defp warned?(key), do: MapSet.member?(warned_set(), key)

  defp mark_warned(key), do: Process.put(__MODULE__, MapSet.put(warned_set(), key))

  defp warned_set, do: Process.get(__MODULE__, MapSet.new())
end

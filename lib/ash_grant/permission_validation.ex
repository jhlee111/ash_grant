defmodule AshGrant.PermissionValidation do
  @moduledoc """
  Validates permissions: a request-time rule for the permissions an actor
  resolves to, and a static checker for the strings an application stores.

  ## Request time: `validate/3`

  Enforces one rule (issue #117): a permission that is a **deny** (`!` prefix)
  must not carry a **field_group** (5th part). A field-group deny is invalid
  because field-group access is positive-only — column restrictions belong in
  the resource's `field_group` definition (`inherits`/`except`/`mask`), and a
  deny carrying a field_group currently over-denies the *entire* action
  (fail-closed) rather than the named group.

  The validator never changes the authorization outcome; it only *signals* the
  invalid permission according to the configured mode:

    * `:off`    — do nothing
    * `:warn`   — emit a `Logger.warning` (deduplicated per process)
    * `:strict` — raise `AshGrant.PermissionValidation.InvalidPermissionError`

  The mode is configured per resource via the `field_group_permissions` option in
  the `ash_grant` DSL block (default `:warn`).

  ## Ahead of time: `check/2` and `check_all/2`

  Permission strings are runtime data — a roles table, a seed file, a migration.
  The compiler never sees them, so nothing stops a stored string from naming a
  resource, action, scope or field group that does not exist. Most of those fail
  silently (the grant is inert, or the fields stay forbidden); an undeclared
  scope **raises inside the check**, on whatever request first reaches it. A
  rename in code orphans every stored string that used the old name.

  `check/2` compares one permission against the application's resources and
  returns a list of issues; `check_all/2` does the same for a whole table or
  file. Run them wherever the strings live:

      # One string, e.g. from an admin form
      AshGrant.PermissionValidation.check("post:*:read:own", otp_app: :my_app)
      #=> []

      # Every stored grant, e.g. in a deploy step
      MyApp.Role
      |> MyApp.Repo.all()
      |> Enum.flat_map(& &1.permissions)
      |> AshGrant.PermissionValidation.check_all(otp_app: :my_app)
      |> Enum.reject(fn {_permission, issues} -> issues == [] end)

  `AshGrant.Validations.PermissionStrings` wraps this as an Ash validation for
  the attribute that stores grants, and `mix ash_grant.check_permissions` wraps
  it for CI. Like `validate/3`, none of this changes an authorization outcome.

  ### Issue codes

  | Code | Segment | Severity | Meaning |
  |------|---------|----------|---------|
  | `:parse_error` | `:permission` | error | `AshGrant.Permission.parse/1` rejects the string |
  | `:unknown_resource` | `:resource` | error | not `*`, and no configured resource answers to that name |
  | `:unknown_action` | `:action` | error | a literal action name no targeted resource has |
  | `:unknown_action_type` | `:action` | error | from `AshGrant.Permission.diagnostics/1` |
  | `:deprecated_type_wildcard` | `:action` | warning | from `AshGrant.Permission.diagnostics/1` |
  | `:dead_instance_type_wildcard` | `:action` | warning | from `AshGrant.Permission.diagnostics/1` |
  | `:undeclared_scope` | `:scope` | error¹ | no resource the grant applies to declares the scope |
  | `:scope_missing_on` | `:scope` | error¹ | some of the resources the grant applies to lack the scope — listed in `:resources` |
  | `:unverifiable_scope` | `:scope` | warning | undeclared, but a `scope_resolver` is configured and may know it |
  | `:unknown_field_group` | `:field_group` | error | no resource the grant applies to declares the field group |
  | `:field_group_missing_on` | `:field_group` | error | some of the resources the grant applies to lack the field group — listed in `:resources` |
  | `:deny_with_field_group` | `:field_group` | error | the rule `validate/3` enforces at request time |

  ¹ A warning on a **deny** or an **instance** permission: the framework never
  resolves those scopes (a deny applies whatever its scope; an instance scope is
  the application's to read via `AshGrant.Evaluator.get_instance_scope/3`), so an
  undeclared one cannot raise.

  ### What "the resources the grant applies to" means

  A scope is only resolved on a resource where the grant matches an action. So
  `*:*:approve:own_unit` needs `own_unit` on every resource that has an `approve`
  action — not on every resource in the application. The same goes for a resource
  name shared by several resources. A grant that matches no action anywhere is
  reported for its action alone — nothing reads its scope or field group until
  that is fixed. Field groups add one exemption: under a `*`
  or shared name, a resource that declares no field groups at all is skipped,
  since the 5th segment has nothing to restrict there.

  ### Which names count as declared

    * **Resource** — `AshGrant.Info.resource_name/1`, plus any string
      `resource:` override passed to an AshGrant check in the resource's policies.
    * **Action** — the resource's actions, plus any `action:` override
      (`AshGrant.check(action: "publish")`) in its policies or `CanPerform`
      calculations. An **instance** permission may also name an action of any
      resource that `scope_through`s this one: the checks match the parent's
      instance permissions against the child's action.
    * **Scope** — `AshGrant.Info.scopes/1` (domain-inherited scopes included),
      plus `always` and `all`, which every check accepts without a declaration.
      `global` is accepted by name on the read path only; `AshGrant.Check` raises
      on it, so an undeclared `global` is reported whenever the grant can reach a
      write or generic action.
    * **Field group** — `AshGrant.Info.field_groups/1`.
  """

  require Logger

  alias AshGrant.Permission
  alias AshGrant.PermissionValidation.ResourceIndex

  defmodule InvalidPermissionError do
    @moduledoc """
    Raised in `:strict` mode when an actor's permissions contain a deny rule that
    carries a field_group — an invalid combination. See `AshGrant.PermissionValidation`.
    """
    defexception [:message]
  end

  @type mode :: :off | :warn | :strict

  @typedoc """
  A problem `check/2` found in one permission.

  `segment` is the part of the string at fault (`:permission` for a string that
  does not parse). `resources` lists the resource modules the issue is about —
  the ones lacking the scope or field group — and is `[]` when the issue is not
  about particular resources.
  """
  @type issue :: %{
          code: atom(),
          severity: :error | :warning,
          segment: :permission | :resource | :action | :scope | :field_group,
          message: String.t(),
          permission: String.t(),
          resources: [module()]
        }

  # Scopes every check accepts without a declaration — the clauses that sit above
  # the "not found in inline scope DSL" raise in Check, FilterCheck and CanPerform.
  @builtin_scopes ~w(always all)

  # Accepted by name on the read path (FilterCheck, FieldFilterCheck, CanPerform)
  # but not by AshGrant.Check, which raises on it (#139).
  @read_only_builtin_scopes ~w(global)

  @diagnostic_severities %{
    deprecated_type_wildcard: :warning,
    # A warning, not an error: the read-filter path does match these (#131), so
    # "never matches" is not yet true everywhere.
    dead_instance_type_wildcard: :warning,
    unknown_action_type: :error
  }

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

  @doc """
  Checks one permission against the application's resources.

  Returns `[]` when every segment names something that exists, otherwise one
  issue per problem — see the moduledoc for the codes. Accepts a string, an
  `%AshGrant.Permission{}`, an `%AshGrant.PermissionInput{}` or anything
  implementing `AshGrant.Permissionable`.

  ## Options

    * `:resources` — the resource modules to check against.
    * `:otp_app` — read the resources from that application's `:ash_domains`
      instead.

  With neither, every AshGrant resource in the started applications'
  `:ash_domains` is used (`AshGrant.Introspect.list_resources/0`). Resources
  without the AshGrant extension or without a resolver are ignored either way.

  ## Examples

      AshGrant.PermissionValidation.check("post:*:read:own", resources: [MyApp.Blog.Post])
      #=> []

      AshGrant.PermissionValidation.check("post:*:read:owm", resources: [MyApp.Blog.Post])
      #=> [
      #=>   %{
      #=>     code: :undeclared_scope,
      #=>     severity: :error,
      #=>     segment: :scope,
      #=>     message: "Scope `owm` is not declared on MyApp.Blog.Post. The check raises " <>
      #=>       "when it resolves this scope. Did you mean `own`?",
      #=>     permission: "post:*:read:owm",
      #=>     resources: [MyApp.Blog.Post]
      #=>   }
      #=> ]

  """
  @spec check(term(), keyword()) :: [issue()]
  def check(permission, opts \\ []) do
    check_one(permission, ResourceIndex.build(opts))
  end

  @doc """
  Checks many permissions against the application's resources.

  Returns one `{permission, issues}` pair per input, in input order, so a caller
  can point at the offending row. Takes the same options as `check/2` and reads
  the resources once for the whole list.
  """
  @spec check_all(Enumerable.t(), keyword()) :: [{term(), [issue()]}]
  def check_all(permissions, opts \\ []) do
    index = ResourceIndex.build(opts)
    Enum.map(permissions, &{&1, check_one(&1, index)})
  end

  @doc """
  Returns true when `issues` contains at least one `:error`.
  """
  @spec errors?([issue()]) :: boolean()
  def errors?(issues), do: Enum.any?(issues, &(&1.severity == :error))

  defp check_one(permission, index) do
    case to_permission(permission) do
      {:ok, perm} ->
        check_permission(perm, index)

      {:error, reason} ->
        [issue(:parse_error, :error, :permission, display(permission), reason)]
    end
  end

  defp to_permission(string) when is_binary(string), do: Permission.parse(string)
  defp to_permission(%Permission{} = perm), do: {:ok, perm}

  defp to_permission(other) do
    [perm] = AshGrant.Evaluator.normalize_permissions([other])
    {:ok, perm}
  rescue
    _ -> {:error, "Not a permission: #{inspect(other)}"}
  end

  defp display(permission) when is_binary(permission), do: permission
  defp display(permission), do: inspect(permission)

  defp check_permission(perm, index) do
    string = Permission.to_string(perm)

    case targets(perm, index) do
      [] ->
        [unknown_resource(perm, string, index) | action_syntax_issues(perm, string)] ++
          deny_field_group_issues(perm, string)

      targets ->
        # A scope or field group is only read where the grant matches an action,
        # so those are the only resources that owe it one. A grant that matches
        # nowhere is reported for its action alone: nothing reads the rest.
        readers = Enum.filter(targets, &applies?(&1, perm))
        broad? = perm.resource == "*" or length(targets) > 1

        action_syntax_issues(perm, string) ++
          unknown_action_issues(perm, string, targets, readers) ++
          scope_issues(perm, string, readers) ++
          field_group_issues(perm, string, readers, broad?)
    end
  end

  # -- resource ---------------------------------------------------------------

  defp targets(%Permission{resource: "*"}, index), do: index
  defp targets(%Permission{resource: name}, index), do: Enum.filter(index, &(name in &1.names))

  # An empty index means the caller pointed at the wrong place, not that every
  # string is wrong — say so rather than suggesting the names are misspelt.
  defp unknown_resource(_perm, string, []) do
    issue(
      :unknown_resource,
      :error,
      :resource,
      string,
      "No AshGrant resources to check against. Pass `resources:`, or an `otp_app:` " <>
        "whose `:ash_domains` lists them."
    )
  end

  defp unknown_resource(perm, string, index) do
    known = index |> Enum.flat_map(& &1.names) |> Enum.uniq()

    issue(
      :unknown_resource,
      :error,
      :resource,
      string,
      "No AshGrant resource is named `#{perm.resource}`, so this grant matches nothing." <>
        did_you_mean(perm.resource, known)
    )
  end

  # -- action -----------------------------------------------------------------

  defp action_syntax_issues(perm, string) do
    for diagnostic <- Permission.diagnostics(perm) do
      severity = Map.fetch!(@diagnostic_severities, diagnostic.code)
      issue(diagnostic.code, severity, :action, string, diagnostic.message)
    end
  end

  defp unknown_action_issues(perm, string, targets, []) do
    if literal_action?(perm) do
      known = targets |> Enum.flat_map(&action_names/1) |> Enum.uniq()

      [
        issue(
          :unknown_action,
          :error,
          :action,
          string,
          "#{describe_resources(targets)} an action named `#{perm.action}`, so this " <>
            "grant matches nothing." <> did_you_mean(perm.action, known),
          Enum.map(targets, & &1.resource)
        )
      ]
    else
      []
    end
  end

  defp unknown_action_issues(_perm, _string, _targets, _applicable), do: []

  defp literal_action?(perm), do: perm.action != "*" and not Permission.type_wildcard?(perm)

  defp action_names(entry) do
    Map.keys(entry.actions) ++
      entry.action_overrides ++ Enum.map(entry.through_actions, &elem(&1, 0))
  end

  # Uses the runtime's own matcher so the two cannot drift. An overridden action
  # name reaches the evaluator with no action type, which is what `nil` mirrors.
  defp applies?(entry, perm) do
    Enum.any?(matchable_actions(entry, perm), fn {name, type} ->
      Permission.matches_action?(perm.action, name, type)
    end) or Enum.any?(entry.action_overrides, &Permission.matches_action?(perm.action, &1, nil))
  end

  # An instance permission also reaches the children that `scope_through` this
  # resource, under the child's action.
  defp matchable_actions(entry, perm) do
    if Permission.instance_permission?(perm),
      do: Enum.concat(entry.actions, entry.through_actions),
      else: entry.actions
  end

  # -- scope ------------------------------------------------------------------

  defp scope_issues(%Permission{scope: nil}, _string, _readers), do: []

  defp scope_issues(perm, string, readers) do
    statuses = Enum.group_by(readers, &scope_status(&1, perm), & &1.resource)
    missing = Map.get(statuses, :missing, [])
    unverifiable = Map.get(statuses, :unverifiable, [])
    severity = if runtime_resolves_scope?(perm), do: :error, else: :warning

    missing_scope_issues(perm, string, readers, missing, Map.has_key?(statuses, :ok), severity) ++
      unverifiable_scope_issues(perm, string, unverifiable)
  end

  defp scope_status(entry, perm) do
    cond do
      MapSet.member?(entry.scopes, perm.scope) -> :ok
      perm.scope in @builtin_scopes -> :ok
      perm.scope in @read_only_builtin_scopes and not write_reachable?(entry, perm.action) -> :ok
      entry.scope_resolver? -> :unverifiable
      true -> :missing
    end
  end

  # True when the grant can be evaluated by AshGrant.Check: it matches a non-read
  # action, or a name that a Check in the resource's policies overrides to.
  defp write_reachable?(entry, pattern) do
    Enum.any?(entry.actions, fn {name, type} ->
      type != :read and Permission.matches_action?(pattern, name, type)
    end) or Enum.any?(entry.write_action_overrides, &Permission.matches_action?(pattern, &1, nil))
  end

  # The framework resolves a scope only for an allow RBAC grant. A deny applies
  # whatever its scope, and an instance grant contributes its id alone.
  defp runtime_resolves_scope?(perm),
    do: not perm.deny and not Permission.instance_permission?(perm)

  defp missing_scope_issues(_perm, _string, _readers, [], _any_ok?, _severity), do: []

  defp missing_scope_issues(perm, string, readers, missing, any_ok?, severity) do
    known = readers |> Enum.flat_map(& &1.scopes) |> Enum.uniq()
    consequence = scope_consequence(perm)

    {code, message} =
      if any_ok? do
        {:scope_missing_on,
         "Scope `#{perm.scope}` is not declared on #{inspect_list(missing)}, which this " <>
           "grant also applies to. #{consequence}"}
      else
        {:undeclared_scope,
         "Scope `#{perm.scope}` is not declared on #{inspect_list(missing)}. " <>
           consequence <> did_you_mean(perm.scope, known ++ @builtin_scopes)}
      end

    [issue(code, severity, :scope, string, message, missing)]
  end

  defp scope_consequence(perm) do
    cond do
      perm.deny ->
        "A deny applies whatever its scope, so the scope is never read."

      Permission.instance_permission?(perm) ->
        "The framework never resolves an instance permission's scope, so nothing raises — " <>
          "but `AshGrant.Evaluator.get_instance_scope/3` will hand back a name with no definition."

      true ->
        "The check raises when it resolves this scope."
    end
  end

  defp unverifiable_scope_issues(_perm, _string, []), do: []

  defp unverifiable_scope_issues(perm, string, unverifiable) do
    [
      issue(
        :unverifiable_scope,
        :warning,
        :scope,
        string,
        "Scope `#{perm.scope}` is not declared on #{inspect_list(unverifiable)}, but a " <>
          "`scope_resolver` is configured there and may resolve it. It cannot be checked ahead of time.",
        unverifiable
      )
    ]
  end

  # -- field group ------------------------------------------------------------

  defp field_group_issues(%Permission{field_group: nil}, _string, _readers, _broad?), do: []

  defp field_group_issues(%Permission{deny: true} = perm, string, _readers, _broad?),
    do: deny_field_group_issues(perm, string)

  defp field_group_issues(perm, string, readers, broad?) do
    # Under `*` or a shared name, a resource with no field groups has nothing for
    # the 5th segment to restrict, so it is not expected to declare this one.
    readers = if broad?, do: Enum.reject(readers, &Enum.empty?(&1.field_groups)), else: readers

    {declaring, lacking} =
      Enum.split_with(readers, &MapSet.member?(&1.field_groups, perm.field_group))

    missing = Enum.map(lacking, & &1.resource)
    known = readers |> Enum.flat_map(& &1.field_groups) |> Enum.uniq()

    cond do
      declaring == [] ->
        [
          issue(
            :unknown_field_group,
            :error,
            :field_group,
            string,
            "Field group `#{perm.field_group}` is not declared on " <>
              "#{if missing == [], do: "any resource", else: inspect_list(missing)}, so this " <>
              "grant makes no field visible." <> did_you_mean(perm.field_group, known),
            missing
          )
        ]

      missing != [] ->
        [
          issue(
            :field_group_missing_on,
            :error,
            :field_group,
            string,
            "Field group `#{perm.field_group}` is not declared on #{inspect_list(missing)}, " <>
              "which this grant also applies to. It makes no field visible there.",
            missing
          )
        ]

      true ->
        []
    end
  end

  defp deny_field_group_issues(%Permission{deny: true, field_group: group} = _perm, string)
       when not is_nil(group) do
    [
      issue(
        :deny_with_field_group,
        :error,
        :field_group,
        string,
        "A deny rule cannot carry a field_group: it over-denies the entire action " <>
          "(fail-closed) rather than the named group. Field-group access is positive-only — " <>
          "express column restrictions in the resource's field_group definition."
      )
    ]
  end

  defp deny_field_group_issues(_perm, _string), do: []

  # -- helpers ----------------------------------------------------------------

  defp issue(code, severity, segment, permission, message, resources \\ []) do
    %{
      code: code,
      severity: severity,
      segment: segment,
      message: message,
      permission: permission,
      resources: resources
    }
  end

  defp describe_resources([entry]), do: "#{inspect(entry.resource)} does not have"
  defp describe_resources(_entries), do: "No targeted resource has"

  defp inspect_list(modules), do: Enum.map_join(modules, ", ", &inspect/1)

  defp did_you_mean(name, candidates) do
    candidates
    |> Enum.map(&{String.jaro_distance(name, &1), &1})
    |> Enum.filter(fn {distance, _candidate} -> distance >= 0.75 end)
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> ""
      {_distance, candidate} -> " Did you mean `#{candidate}`?"
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

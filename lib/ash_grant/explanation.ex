defmodule AshGrant.Explanation do
  @moduledoc """
  Represents a detailed explanation of an authorization decision.

  This struct is returned by `AshGrant.explain/4` and provides comprehensive
  information about why an authorization check succeeded or failed.

  ## Fields

  - `:resource` - The Ash resource being checked
  - `:action` - The action being checked (e.g., `:read`, `:update`)
  - `:actor` - The actor performing the action
  - `:context` - Optional context passed to the check
  - `:decision` - The final decision (`:allow` or `:deny`)
  - `:reason` - Reason for denial (`:no_matching_permissions`, `:denied_by_rule`, etc.)
  - `:matching_permissions` - List of permissions that matched and granted access
  - `:evaluated_permissions` - All permissions that were evaluated with match status
  - `:scope_filter` - The resolved scope filter expression (for reads)
  - `:field_groups` - List of field group names the actor has access to (from 5-part permissions)
  - `:field_group_defs` - Field group definitions from the resource DSL

  ## Example

      iex> result = AshGrant.explain(MyApp.Post, :read, actor)
      %AshGrant.Explanation{
        resource: MyApp.Post,
        action: :read,
        decision: :allow,
        matching_permissions: [
          %{
            permission: "post:*:read:always",
            description: "Read all posts",
            source: "editor_role",
            scope_name: :all,
            scope_description: "All records without restriction",
            field_group: nil
          }
        ],
        field_groups: [],
        field_group_defs: [],
        ...
      }

      iex> AshGrant.Explanation.to_string(result)
      \"\"\"
      ═══════════════════════════════════════════════════════════════════
      Authorization Explanation for MyApp.Post
      ═══════════════════════════════════════════════════════════════════
      Action:   read
      Decision: ✓ ALLOW
      ...
      \"\"\"

  """

  @type evaluated_permission :: %{
          permission: String.t(),
          matched: boolean(),
          reason: String.t() | nil,
          description: String.t() | nil,
          source: String.t() | nil,
          scope_name: atom() | nil,
          scope_description: String.t() | nil,
          field_group: String.t() | nil
        }

  @type t :: %__MODULE__{
          resource: module(),
          action: atom(),
          actor: term(),
          context: map() | nil,
          decision: :allow | :deny,
          reason: atom() | nil,
          matching_permissions: [evaluated_permission()],
          evaluated_permissions: [evaluated_permission()],
          scope_filter: term() | nil,
          field_groups: [String.t()],
          field_group_defs: [AshGrant.Dsl.FieldGroup.t()]
        }

  defstruct [
    :resource,
    :action,
    :actor,
    :context,
    :decision,
    :reason,
    :scope_filter,
    matching_permissions: [],
    evaluated_permissions: [],
    field_groups: [],
    field_group_defs: []
  ]

  @doc """
  Converts an Explanation struct to a human-readable string.

  ## Options

  - `:color` - Whether to include ANSI color codes (default: `true`)
  - `:verbose` - Whether to include all evaluated permissions (default: `false`)

  ## Example

      iex> result = AshGrant.explain(MyApp.Post, :read, actor)
      iex> IO.puts(AshGrant.Explanation.to_string(result))
      ═══════════════════════════════════════════════════════════════════
      Authorization Explanation for MyApp.Post
      ═══════════════════════════════════════════════════════════════════
      Action:   read
      Decision: ✓ ALLOW
      ...

  """
  @spec to_string(t(), keyword()) :: String.t()
  def to_string(%__MODULE__{} = explanation, opts \\ []) do
    color = Keyword.get(opts, :color, true)
    verbose = Keyword.get(opts, :verbose, false)

    [
      header(explanation, color),
      summary(explanation, color),
      matching_section(explanation, color),
      if(verbose, do: evaluated_section(explanation, color), else: nil),
      scope_section(explanation, color),
      field_group_section(explanation, color),
      footer(color)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Private formatting functions

  defp header(explanation, color) do
    resource_name = inspect(explanation.resource)
    line = String.duplicate("═", 67)

    """
    #{maybe_color(line, :cyan, color)}
    Authorization Explanation for #{maybe_color(resource_name, :bright, color)}
    #{maybe_color(line, :cyan, color)}
    """
  end

  defp summary(explanation, color) do
    decision_str = format_decision(explanation.decision, color)
    reason_str = if explanation.reason, do: " (#{explanation.reason})", else: ""

    """
    Action:   #{explanation.action}
    Decision: #{decision_str}#{reason_str}
    Actor:    #{inspect(explanation.actor)}
    """
  end

  defp format_decision(:allow, color) do
    maybe_color("✓ ALLOW", :green, color)
  end

  defp format_decision(:deny, color) do
    maybe_color("✗ DENY", :red, color)
  end

  defp matching_section(%{matching_permissions: []} = _explanation, _color) do
    """
    Matching Permissions: (none)
    """
  end

  defp matching_section(explanation, color) do
    permissions =
      Enum.map_join(explanation.matching_permissions, "\n", &format_permission(&1, color))

    """
    Matching Permissions:
    #{permissions}
    """
  end

  defp format_permission(perm, color) do
    scope_info =
      if perm[:scope_name] do
        scope_desc =
          if perm[:scope_description],
            do: " - #{perm[:scope_description]}",
            else: ""

        " [scope: #{perm[:scope_name]}#{scope_desc}]"
      else
        ""
      end

    source_info = if perm[:source], do: " (from: #{perm[:source]})", else: ""

    field_group_info =
      if perm[:field_group], do: " [field_group: #{perm[:field_group]}]", else: ""

    desc_info = if perm[:description], do: "\n    └─ #{perm[:description]}", else: ""

    "  • #{maybe_color(perm[:permission], :yellow, color)}#{scope_info}#{field_group_info}#{source_info}#{desc_info}"
  end

  defp evaluated_section(%{evaluated_permissions: []} = _explanation, _color) do
    nil
  end

  defp evaluated_section(explanation, color) do
    permissions =
      Enum.map_join(
        explanation.evaluated_permissions,
        "\n",
        &format_evaluated_permission(&1, color)
      )

    """

    All Evaluated Permissions:
    #{permissions}
    """
  end

  defp format_evaluated_permission(perm, color) do
    status =
      if perm[:matched],
        do: maybe_color("✓", :green, color),
        else: maybe_color("✗", :red, color)

    reason = if perm[:reason], do: " - #{perm[:reason]}", else: ""

    "  #{status} #{perm[:permission]}#{reason}"
  end

  defp field_group_section(%{field_groups: [], field_group_defs: []} = _explanation, _color),
    do: nil

  defp field_group_section(%{field_groups: [], field_group_defs: defs} = _explanation, color)
       when defs != [] do
    groups_info =
      Enum.map_join(defs, "\n", fn fg ->
        name = Atom.to_string(fg.name)

        inherits =
          if fg.inherits && fg.inherits != [],
            do: " (inherits: #{inspect(fg.inherits)})",
            else: ""

        "  • #{maybe_color(name, :yellow, color)}: #{inspect(fg.fields)}#{inherits}"
      end)

    """

    Field Groups (defined, but actor has no field_group restriction):
    #{groups_info}
    """
  end

  defp field_group_section(explanation, color) do
    actor_groups = explanation.field_groups |> Enum.join(", ")

    groups_info =
      Enum.map_join(explanation.field_group_defs, "\n", fn fg ->
        name = Atom.to_string(fg.name)

        inherits =
          if fg.inherits && fg.inherits != [],
            do: " (inherits: #{inspect(fg.inherits)})",
            else: ""

        "  • #{maybe_color(name, :yellow, color)}: #{inspect(fg.fields)}#{inherits}"
      end)

    """

    Field Groups:
      Actor's groups: #{maybe_color(actor_groups, :bright, color)}
    #{groups_info}
    """
  end

  defp scope_section(%{scope_filter: nil} = _explanation, _color), do: nil

  defp scope_section(explanation, color) do
    filter_str =
      case explanation.scope_filter do
        true -> "true (no filtering)"
        false -> "false (deny all)"
        expr -> inspect(expr)
      end

    """

    Scope Filter: #{maybe_color(filter_str, :cyan, color)}
    """
  end

  defp footer(color) do
    line = String.duplicate("─", 67)
    maybe_color(line, :cyan, color)
  end

  defp maybe_color(text, _color, false), do: text

  defp maybe_color(text, color, true) do
    IO.ANSI.format([color, text, :reset])
    |> IO.iodata_to_binary()
  end
end

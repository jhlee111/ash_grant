defmodule AshGrant.PolicyTest.AssertionError do
  @moduledoc """
  Error raised when a policy test assertion fails.
  """
  defexception [:message]

  @impl true
  def exception(opts) do
    message = Keyword.fetch!(opts, :message)
    %__MODULE__{message: message}
  end
end

defmodule AshGrant.PolicyTest.Assertions do
  @moduledoc """
  Assertion macros for policy tests.

  Provides two assertion macros:

  - `assert_can/2` and `assert_can/3` - Assert an actor can perform an action
  - `assert_cannot/2` and `assert_cannot/3` - Assert an actor cannot perform an action

  These macros are automatically imported when you `use AshGrant.PolicyTest`.
  """

  alias AshGrant.PolicyTest.{AssertionError, Checker}

  @doc """
  Asserts that the specified fields are visible to an actor for an action.

  Resolves the actor's field groups for the given action. If the actor has
  4-part permissions (no field_group), all fields are considered visible.
  If field groups exist, only fields in the resolved groups are visible.

  ## Examples

      assert_fields_visible :reader, :read, [:name, :email]
      assert_fields_visible :admin, :read, [:name, :salary, :ssn]
  """
  defmacro assert_fields_visible(actor_name, action_spec, fields) do
    quote do
      AshGrant.PolicyTest.Assertions.do_assert_fields_visible(
        __MODULE__,
        unquote(actor_name),
        unquote(action_spec),
        unquote(fields)
      )
    end
  end

  @doc """
  Asserts that the specified fields are hidden from an actor for an action.

  Resolves the actor's field groups for the given action. If the actor has
  4-part permissions (no field_group), no fields are hidden and this assertion
  will fail. If the actor is denied, all fields are hidden.

  ## Examples

      assert_fields_hidden :reader, :read, [:salary, :ssn]
      assert_fields_hidden :guest, :read, [:name, :email]
  """
  defmacro assert_fields_hidden(actor_name, action_spec, fields) do
    quote do
      AshGrant.PolicyTest.Assertions.do_assert_fields_hidden(
        __MODULE__,
        unquote(actor_name),
        unquote(action_spec),
        unquote(fields)
      )
    end
  end

  @doc """
  Asserts that an actor can perform an action.

  ## Action Specifiers

  The second argument can be:
  - An atom for action name shorthand: `:read`, `:update`
  - A keyword list with `:action` or `:action_type`

  ## Third argument — record and/or arguments

  The third argument may be:
  - omitted — check permission only
  - a bare map — treated as the record attributes
  - a keyword list with `:record` and/or `:arguments` — the latter supplies
    action-argument values for scopes that use `^arg(:name)` templates
    (see `resolve_argument` and `guides/argument-based-scope.md`)

  ## Examples

      # Actor can perform :read action
      assert_can :reader, :read

      # Actor can perform specific action
      assert_can :author, action: :submit_for_review

      # Actor can perform any action of type
      assert_can :editor, action_type: :update

      # Actor can access record with specific attributes
      assert_can :reader, :read, %{status: :published}

      # Argument-based scope — actor, record, AND action arguments
      assert_can :manager, :update,
        record: %{author_id: "u1"},
        arguments: %{center_id: "center_A"}
  """
  defmacro assert_can(actor_name, action_spec) do
    quote do
      AshGrant.PolicyTest.Assertions.do_assert_can(
        __MODULE__,
        unquote(actor_name),
        unquote(action_spec),
        nil
      )
    end
  end

  defmacro assert_can(actor_name, action_spec, record) do
    quote do
      AshGrant.PolicyTest.Assertions.do_assert_can(
        __MODULE__,
        unquote(actor_name),
        unquote(action_spec),
        unquote(record)
      )
    end
  end

  @doc """
  Asserts that an actor cannot perform an action.

  See `assert_can/3` for the accepted third-argument forms (bare record map
  or `record:`/`arguments:` keyword list).

  ## Examples

      # Actor cannot perform :delete action
      assert_cannot :viewer, :delete

      # Actor cannot access record with specific attributes
      assert_cannot :reader, :read, %{status: :draft}

      # Argument-based scope — verify a value *outside* the actor's units is denied
      assert_cannot :manager, :update,
        record: %{author_id: "u1"},
        arguments: %{center_id: "center_Z"}
  """
  defmacro assert_cannot(actor_name, action_spec) do
    quote do
      AshGrant.PolicyTest.Assertions.do_assert_cannot(
        __MODULE__,
        unquote(actor_name),
        unquote(action_spec),
        nil
      )
    end
  end

  defmacro assert_cannot(actor_name, action_spec, record) do
    quote do
      AshGrant.PolicyTest.Assertions.do_assert_cannot(
        __MODULE__,
        unquote(actor_name),
        unquote(action_spec),
        unquote(record)
      )
    end
  end

  @doc false
  def do_assert_can(module, actor_name, action_spec, third) do
    {record, arguments} = split_record_and_arguments(third)
    {actor, resource, action} = resolve_context(module, actor_name, action_spec)

    case Checker.check(resource, actor, action, record, arguments) do
      {:allow, _details} ->
        :ok

      {:deny, details} ->
        raise AssertionError,
          message: build_error_message(:assert_can, actor_name, action_spec, record, details)

      {:indeterminate, details} ->
        raise AssertionError,
          message: undecided_message(actor_name, action_spec, record, details)
    end
  end

  @doc false
  def do_assert_cannot(module, actor_name, action_spec, third) do
    {record, arguments} = split_record_and_arguments(third)
    {actor, resource, action} = resolve_context(module, actor_name, action_spec)

    case Checker.check(resource, actor, action, record, arguments) do
      {:deny, _details} ->
        :ok

      {:allow, details} ->
        raise AssertionError,
          message: build_error_message(:assert_cannot, actor_name, action_spec, record, details)

      {:indeterminate, details} ->
        raise AssertionError,
          message: undecided_message(actor_name, action_spec, record, details)
    end
  end

  # The third arg to assert_can/assert_cannot historically was a bare record
  # map. Users may also pass a keyword list like `[record: %{...}, arguments:
  # %{center_id: "..."}]` to supply both. Returns `{record, arguments}`.
  defp split_record_and_arguments(nil), do: {nil, %{}}

  defp split_record_and_arguments(kw) when is_list(kw) do
    case Keyword.keyword?(kw) do
      true ->
        record = Keyword.get(kw, :record)
        arguments = Keyword.get(kw, :arguments, %{}) || %{}
        {record, arguments}

      false ->
        {nil, %{}}
    end
  end

  defp split_record_and_arguments(record) when is_map(record), do: {record, %{}}

  @doc false
  def do_assert_fields_visible(module, actor_name, action_spec, fields) do
    {actor, resource, _action} = resolve_context(module, actor_name, action_spec)
    action = normalize_action_spec(action_spec)

    visible = resolve_visible_fields(resource, actor, action)

    case visible do
      :all_fields ->
        :ok

      :no_access ->
        raise AssertionError,
          message:
            "Expected fields #{inspect(fields)} to be visible for actor :#{actor_name} " <>
              "performing #{format_action(action_spec)}, but the actor has no permission"

      field_set ->
        hidden = Enum.reject(fields, &(&1 in field_set))

        if hidden == [] do
          :ok
        else
          raise AssertionError,
            message:
              "Expected fields #{inspect(hidden)} to be visible for actor :#{actor_name} " <>
                "performing #{format_action(action_spec)}, but they were hidden. " <>
                "Visible fields: #{inspect(field_set)}"
        end
    end
  end

  @doc false
  def do_assert_fields_hidden(module, actor_name, action_spec, fields) do
    {actor, resource, _action} = resolve_context(module, actor_name, action_spec)
    action = normalize_action_spec(action_spec)

    visible = resolve_visible_fields(resource, actor, action)

    case visible do
      :all_fields ->
        raise AssertionError,
          message:
            "Expected fields #{inspect(fields)} to be hidden for actor :#{actor_name} " <>
              "performing #{format_action(action_spec)}, but the actor has a 4-part permission " <>
              "with no field restriction (all fields visible)"

      :no_access ->
        :ok

      field_set ->
        exposed = Enum.filter(fields, &(&1 in field_set))

        if exposed == [] do
          :ok
        else
          raise AssertionError,
            message:
              "Expected fields #{inspect(exposed)} to be hidden for actor :#{actor_name} " <>
                "performing #{format_action(action_spec)}, but they were visible. " <>
                "Visible fields: #{inspect(field_set)}"
        end
    end
  end

  @doc false
  def resolve_visible_fields(resource, actor, action) do
    permissions = AshGrant.Introspect.permissions_for(resource, actor)
    resource_name = AshGrant.Info.resource_name(resource)
    action_name = normalize_action_to_string(action)

    field_groups =
      AshGrant.Evaluator.get_all_field_groups(permissions, resource_name, action_name)

    has_any_permission = AshGrant.Evaluator.has_access?(permissions, resource_name, action_name)

    cond do
      not has_any_permission -> :no_access
      field_groups == [] -> :all_fields
      true -> resolve_field_groups_to_fields(resource, field_groups)
    end
  end

  defp resolve_field_groups_to_fields(resource, field_groups) do
    field_groups
    |> Enum.flat_map(&resolve_single_field_group(resource, &1))
    |> Enum.uniq()
  end

  defp resolve_single_field_group(resource, group_name) do
    group_atom = if is_binary(group_name), do: String.to_atom(group_name), else: group_name

    case AshGrant.Info.resolve_field_group(resource, group_atom) do
      nil -> []
      resolved -> resolved.fields
    end
  end

  # Private functions

  defp resolve_context(module, actor_name, action_spec) do
    resource = module.__policy_test__(:resource)
    actors = module.__policy_test__(:actors)

    actor = Map.get(actors, actor_name)

    if actor == nil do
      raise AssertionError,
        message:
          "Actor :#{actor_name} not defined. Available actors: #{inspect(Map.keys(actors))}"
    end

    action = normalize_action_spec(action_spec)

    {actor, resource, action}
  end

  defp normalize_action_spec(action_spec) when is_atom(action_spec) do
    action_spec
  end

  defp normalize_action_spec(action: action) when is_atom(action) do
    action
  end

  defp normalize_action_spec(action_type: type) when is_atom(type) do
    {:action_type, type}
  end

  defp normalize_action_spec(spec) when is_list(spec) do
    cond do
      Keyword.has_key?(spec, :action) -> Keyword.fetch!(spec, :action)
      Keyword.has_key?(spec, :action_type) -> {:action_type, Keyword.fetch!(spec, :action_type)}
      true -> raise "Invalid action spec: #{inspect(spec)}"
    end
  end

  @doc false
  defdelegate evaluate_filter_against_record(
                filter,
                record,
                actor,
                resource \\ nil,
                arguments \\ %{}
              ),
              to: Checker

  defp build_error_message(:assert_can, actor_name, action_spec, nil, details) do
    "Expected actor :#{actor_name} to be able to perform #{format_action(action_spec)}, " <>
      "but was denied: #{inspect(details)}"
  end

  defp build_error_message(:assert_can, actor_name, action_spec, record, details) do
    "Expected actor :#{actor_name} to be able to perform #{format_action(action_spec)} " <>
      "on record #{inspect(record)}, but was denied: #{inspect(details)}"
  end

  defp build_error_message(:assert_cannot, actor_name, action_spec, nil, details) do
    "Expected actor :#{actor_name} to NOT be able to perform #{format_action(action_spec)}, " <>
      "but was allowed: #{inspect(details)}"
  end

  defp build_error_message(:assert_cannot, actor_name, action_spec, record, details) do
    "Expected actor :#{actor_name} to NOT be able to perform #{format_action(action_spec)} " <>
      "on record #{inspect(record)}, but was allowed: #{inspect(details)}"
  end

  defp undecided_message(actor_name, action_spec, record, details) do
    "Cannot decide whether actor :#{actor_name} can perform #{format_action(action_spec)} " <>
      "on record #{inspect(record)}: #{Checker.undecided_reason(details)}"
  end

  defp format_action(action) when is_atom(action), do: ":#{action}"
  defp format_action({:action_type, type}), do: "action_type: :#{type}"
  defp format_action(action: action), do: "action: :#{action}"
  defp format_action(action_type: type), do: "action_type: :#{type}"
  defp format_action(other), do: inspect(other)

  defp normalize_action_to_string(action) when is_atom(action), do: Atom.to_string(action)

  defp normalize_action_to_string({:action_type, _type}),
    do: raise("assert_fields_visible/assert_fields_hidden does not support action_type specs")

  defp normalize_action_to_string(action) when is_binary(action), do: action
end

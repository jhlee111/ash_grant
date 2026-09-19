defmodule AshGrant.Validations.PermissionStrings do
  @moduledoc """
  An Ash validation for the attribute where an application stores grants.

  Runs `AshGrant.PermissionValidation.check_all/2` over the value being written
  and adds one field error per bad string, naming the string — so an admin UI
  rejects a typo at the form instead of storing a grant that is inert, or that
  raises on the first request to reach it.

      validations do
        validate {AshGrant.Validations.PermissionStrings, attribute: :permissions}
      end

  The value may be a list of permission strings, a single string, or `nil`. It
  is only checked when the action changes it: strings already stored are left
  alone, so a rename in code does not block unrelated edits to the same record.
  Scan stored strings with `mix ash_grant.check_permissions` instead.

  ## Options

    * `:attribute` — required. The attribute (or action argument) holding the
      permission strings.
    * `:otp_app` / `:resources` — which resources to check against, as in
      `AshGrant.PermissionValidation.check/2`. With neither, every AshGrant
      resource in the started applications' `:ash_domains` is used.
    * `:reject` — `:errors` (default) rejects only issues of severity `:error`;
      `:warnings` rejects warnings too.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias AshGrant.PermissionValidation

  @impl true
  def init(opts) do
    cond do
      not is_atom(opts[:attribute]) or is_nil(opts[:attribute]) ->
        {:error, "attribute must be an atom, got: #{inspect(opts[:attribute])}"}

      Keyword.get(opts, :reject, :errors) not in [:errors, :warnings] ->
        {:error, "reject must be :errors or :warnings, got: #{inspect(opts[:reject])}"}

      true ->
        {:ok, opts}
    end
  end

  @impl true
  def describe(opts) do
    [
      message: "must contain only permissions that match the application's resources",
      vars: [field: opts[:attribute]]
    ]
  end

  @impl true
  def validate(changeset, opts, _context) do
    case Ash.Changeset.fetch_argument_or_change(changeset, opts[:attribute]) do
      {:ok, value} -> check_value(value, opts)
      :error -> :ok
    end
  end

  # The value is compared against resource metadata, which no data layer can do.
  # A literal change is still checked here; only an expression is out of reach.
  @impl true
  def atomic(changeset, opts, context) do
    if Keyword.has_key?(changeset.atomics, opts[:attribute]) do
      {:not_atomic,
       "cannot check permission strings on `#{opts[:attribute]}` while it is changed by an expression"}
    else
      validate(changeset, opts, context)
    end
  end

  defp check_value(nil, _opts), do: :ok

  defp check_value(value, opts) do
    rejected =
      case Keyword.get(opts, :reject, :errors) do
        :errors -> [:error]
        :warnings -> [:error, :warning]
      end

    value
    |> List.wrap()
    |> PermissionValidation.check_all(Keyword.take(opts, [:otp_app, :resources]))
    |> Enum.flat_map(fn {permission, issues} ->
      case Enum.filter(issues, &(&1.severity in rejected)) do
        [] -> []
        rejected_issues -> [to_error(rejected_issues, permission, opts[:attribute])]
      end
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # One error per bad string, however many segments of it are wrong.
  defp to_error([first | _] = issues, permission, attribute) do
    InvalidAttribute.exception(
      field: attribute,
      value: permission,
      message: "%{permission}: %{reason}",
      vars: [
        permission: first.permission,
        reason: Enum.map_join(issues, " ", & &1.message),
        codes: Enum.map(issues, & &1.code)
      ]
    )
  end
end

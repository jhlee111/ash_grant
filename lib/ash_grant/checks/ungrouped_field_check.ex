defmodule AshGrant.UngroupedFieldCheck do
  @moduledoc """
  Field-policy check that shows fields outside every `field_group` unless the
  resource sets `deny_fields_by_default`.

  `AshGrant.Transformers.AddFieldPolicies` generates it for the ungrouped fields
  of a resource with `default_field_policies true`. Pass `resource:` in the
  check options.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "field is outside every field group and deny_fields_by_default is off"

  @impl true
  def match?(_actor, _context, opts) do
    not AshGrant.Info.deny_fields_by_default?(Keyword.fetch!(opts, :resource))
  end
end

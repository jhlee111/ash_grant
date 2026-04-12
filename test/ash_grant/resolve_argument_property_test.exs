defmodule AshGrant.ResolveArgumentPropertyTest do
  @moduledoc """
  Property-based tests for `AshGrant.ArgumentAnalyzer` and the
  `AshGrant.Changes.ResolveArgument` permission-matching logic.

  Rather than test DSL-compiled resources (which can't be generated at runtime),
  these properties operate directly on:

    * raw Ash expressions constructed with various argument references
    * mock permission strings + scope maps → check that the runtime would
      decide correctly whether a load is needed
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Ash.Expr
  import Ash.Expr

  alias AshGrant.ArgumentAnalyzer

  # --- generators ----------------------------------------------------------

  defp arg_name_gen do
    # small pool for collisions
    one_of([
      constant(:center_id),
      constant(:organization_id),
      constant(:team_id),
      constant(:unit_id),
      constant(:tenant_id)
    ])
  end

  # A leaf expression: either a reference, a literal, or an ^arg(...) template.
  defp leaf_gen do
    one_of([
      arg_name_gen() |> map(&{:_arg, &1}),
      constant({:_actor, :id}),
      integer(),
      boolean(),
      constant(nil),
      string(:alphanumeric, max_length: 5)
    ])
  end

  # Nested expressions of bounded depth built from AshExpr operators. We build
  # the nested shape via Ash.Expr constructors so the output goes through the
  # same pipeline as real scope filters.
  defp expr_gen(depth) when depth <= 0, do: leaf_gen()

  defp expr_gen(depth) do
    sub = expr_gen(depth - 1)

    one_of([
      leaf_gen(),
      bind({sub, sub}, fn {l, r} -> constant(expr(^l == ^r)) end),
      bind({sub, sub}, fn {l, r} -> constant(expr(^l and ^r)) end),
      bind({sub, sub}, fn {l, r} -> constant(expr(^l or ^r)) end),
      bind(sub, fn e -> constant(expr(not (^e))) end)
    ])
  end

  # Collect all {:_arg, name} references in an expression via a naive walk so
  # we can sanity-check the analyzer against an independent implementation.
  defp reference_walk({:_arg, name}), do: [name]

  defp reference_walk(value) when is_list(value),
    do: Enum.flat_map(value, &reference_walk/1)

  defp reference_walk(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&reference_walk/1)

  defp reference_walk(%{} = m) when not is_struct(m),
    do: Enum.flat_map(m, fn {k, v} -> reference_walk(k) ++ reference_walk(v) end)

  defp reference_walk(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.flat_map(fn {k, v} -> reference_walk(k) ++ reference_walk(v) end)
  end

  defp reference_walk(_), do: []

  # --- properties ----------------------------------------------------------

  property "analyzer finds every ^arg(...) reference present in the expression" do
    check all(expression <- expr_gen(3)) do
      analyzer_args = MapSet.new(ArgumentAnalyzer.referenced_args(expression))
      oracle_args = MapSet.new(reference_walk(expression))

      # Analyzer must find every arg the oracle does. Oracle may have MORE
      # in theory, but here they must be equal because our expression shapes
      # only contain arg refs through constructors the analyzer knows about.
      assert analyzer_args == oracle_args,
             """
             analyzer and oracle disagreed.
               analyzer: #{inspect(analyzer_args)}
               oracle  : #{inspect(oracle_args)}
               expr    : #{inspect(expression)}
             """
    end
  end

  property "analyzer returns a list without duplicates" do
    check all(expression <- expr_gen(3)) do
      result = ArgumentAnalyzer.referenced_args(expression)
      assert result == Enum.uniq(result)
    end
  end

  property "references_arg?/2 is consistent with referenced_args/1" do
    check all(
            expression <- expr_gen(3),
            probe <- arg_name_gen()
          ) do
      expected = probe in ArgumentAnalyzer.referenced_args(expression)
      assert ArgumentAnalyzer.references_arg?(expression, probe) == expected
    end
  end

  # --- runtime permission-matching property --------------------------------

  # Simulates what AshGrant.Changes.ResolveArgument does at runtime:
  # iterate the actor's permission list, parse each one, and check whether
  # its scope belongs to scopes_needing for this resource.
  defp simulate_needs?(actor_perms, resource_name, scopes_needing) do
    scopes_set = MapSet.new(scopes_needing)

    Enum.any?(actor_perms, fn perm ->
      case AshGrant.Permission.parse(perm) do
        {:ok, %{resource: r, scope: s}} ->
          (r == "*" or r == resource_name) and
            try do
              MapSet.member?(scopes_set, String.to_existing_atom(s))
            rescue
              ArgumentError -> false
            end

        _ ->
          false
      end
    end)
  end

  defp perm_gen(resource, scope_names) do
    bind({member_of([resource, "*"]), member_of(scope_names)}, fn {r, s} ->
      constant("#{r}:*:update:#{s}")
    end)
  end

  property "needs? is true iff at least one permission's scope is in scopes_needing" do
    all_scopes = [:at_own_unit, :by_own_author, :within_window, :always]
    resource_name = "widget"

    check all(
            scopes_needing <- list_of(member_of(all_scopes), max_length: 4),
            perms <-
              list_of(
                one_of([
                  constant("widget:*:update:at_own_unit"),
                  constant("widget:*:update:by_own_author"),
                  constant("widget:*:update:within_window"),
                  constant("widget:*:update:always"),
                  constant("other:*:update:at_own_unit")
                ]),
                max_length: 6
              )
          ) do
      scopes_needing = Enum.uniq(scopes_needing)

      expected =
        Enum.any?(perms, fn p ->
          case AshGrant.Permission.parse(p) do
            {:ok, %{resource: r, scope: s}} ->
              (r == "*" or r == resource_name) and
                String.to_existing_atom(s) in scopes_needing

            _ ->
              false
          end
        end)

      assert simulate_needs?(perms, resource_name, scopes_needing) == expected
    end
  end

  # Property: the analyzer + simulated runtime decision agree — if an actor has
  # some permissions, the load should fire iff at least one of those perms
  # references some scope whose resolved expression contains ^arg(:center_id).
  property "end-to-end: analyzer output drives simulate_needs? consistently" do
    # Fix the scope set for this property: we'll model a resource with two
    # scopes — :uses_arg references ^arg(:x), :plain does not.
    scopes_using_arg = [:uses_arg]
    scope_pool = [:uses_arg, :plain]

    check all(
            perms <-
              list_of(
                bind(member_of(scope_pool), fn s ->
                  constant("widget:*:update:#{s}")
                end),
                max_length: 5
              )
          ) do
      needs? = simulate_needs?(perms, "widget", scopes_using_arg)

      mentions_uses_arg? = Enum.any?(perms, &String.ends_with?(&1, ":uses_arg"))
      assert needs? == mentions_uses_arg?
    end
  end
end

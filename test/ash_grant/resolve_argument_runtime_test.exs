defmodule AshGrant.ResolveArgumentRuntimeTest do
  @moduledoc """
  Runtime regression tests for `AshGrant.Changes.ResolveArgument` (#144):

  - a single-segment `from_path` (leaf attribute on the resource itself)
    resolves on both create and update
  - a resolver returning an unexpected shape resolves conservatively instead
    of raising `CaseClauseError`
  - `split_relationship_path/2` raises clearly on a non-relationship
    intermediate instead of silently truncating the path
  """
  use ExUnit.Case, async: true

  alias AshGrant.Changes.ResolveArgument
  alias AshGrant.Test.DomainArgPost

  defmodule BadShapeArg do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshGrant]

    ash_grant do
      resolver(fn _, _ -> %{unexpected: :shape} end)
      resource_name("bad_shape_arg")
      scope(:at_own_unit, expr(^arg(:center_id) == ^actor(:org_id)))
      resolve_argument(:center_id, from_path: [:org_id])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  describe "split_relationship_path/2" do
    test "raises on a non-relationship intermediate instead of truncating" do
      assert_raise ArgumentError, ~r/not a relationship/, fn ->
        ResolveArgument.split_relationship_path(DomainArgPost, [:org_id, :center_id])
      end
    end

    test "returns a bare leaf for a single-segment path" do
      assert ResolveArgument.split_relationship_path(DomainArgPost, [:org_id]) == {[], :org_id}
    end
  end

  describe "unexpected resolver shape" do
    test "resolves conservatively instead of raising CaseClauseError" do
      org = Ash.UUID.generate()

      # Build a pre-action changeset (unvalidated) so set_argument/2 is allowed.
      action = Ash.Resource.Info.action(BadShapeArg, :create)

      cs = %{
        Ash.Changeset.new(BadShapeArg)
        | action: action,
          action_type: :create,
          attributes: %{org_id: org}
      }

      actor = %{id: Ash.UUID.generate(), org_id: org}
      opts = [name: :center_id, path: [:org_id], scopes_needing: [:at_own_unit]]

      result = ResolveArgument.change(cs, opts, %{actor: actor})

      assert result.arguments[:center_id] == org
    end
  end

  describe "single-segment from_path" do
    test "resolves on create" do
      org = Ash.UUID.generate()

      actor = %{
        id: Ash.UUID.generate(),
        org_ids: [org],
        permissions: ["domain_arg_post:*:create:at_own_unit"]
      }

      result =
        DomainArgPost
        |> Ash.Changeset.for_create(:create, %{org_id: org}, actor: actor)
        |> Ash.create(actor: actor)

      assert {:ok, _} = result
    end

    test "resolves on update" do
      org = Ash.UUID.generate()

      post =
        DomainArgPost
        |> Ash.Changeset.for_create(:create, %{org_id: org}, authorize?: false)
        |> Ash.create!()

      actor = %{
        id: Ash.UUID.generate(),
        org_ids: [org],
        permissions: ["domain_arg_post:*:update:at_own_unit"]
      }

      result =
        post
        |> Ash.Changeset.for_update(:update, %{}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:ok, _} = result
    end
  end
end

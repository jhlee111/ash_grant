defmodule AshGrant.WriteScopeUnionTest do
  @moduledoc """
  E2E tests for OR-composed write scopes (#123).

  A write action must be authorized when ANY matching grant's scope passes.
  Adding a narrow grant on top of a blanket grant must never revoke access —
  grants are additive; `!` deny is the only subtractive device. This mirrors
  the read path (`FilterCheck`) and the UI path (`CanPerform`), which already
  OR-compose all matching grants.

  Uses BulkItem (:always / :own / :team_member / :frozen scopes).
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.BulkItem

  # Inline ETS resource for the `write: false` union cases. It lives here (not
  # in test/support) because the `write:` option emits a compile-time
  # deprecation warning, and CI compiles test/support with --warnings-as-errors;
  # .exs files are only loaded by the test runner, where warnings stay warnings.
  defmodule FrozenItem do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.WriteScopeUnionTest.FrozenDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, _context -> (actor && Map.get(actor, :permissions)) || [] end)
      resource_name("frozen_item")

      scope(:always, true)
      scope(:frozen, [], expr(title == "frozen"), write: false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
    end

    policies do
      policy action_type(:read) do
        authorize_if(AshGrant.filter_check())
      end

      policy action_type([:create, :update, :destroy]) do
        authorize_if(AshGrant.check())
      end
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule FrozenDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshGrant.WriteScopeUnionTest.FrozenItem)
    end
  end

  defp actor_with_perms(perms, id \\ Ash.UUID.generate()) do
    %{id: id, permissions: perms}
  end

  defp create_item!(attrs) do
    BulkItem
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp update_title(item, actor) do
    item
    |> Ash.Changeset.for_update(:update, %{title: "Updated"})
    |> Ash.update(actor: actor)
  end

  describe "additive grants (#123): a narrow grant must not shadow a blanket grant" do
    test "update outside the narrow scope succeeds via the blanket grant (narrow listed first)" do
      actor = actor_with_perms(["item:*:update:own", "item:*:*:always"])
      item = create_item!(%{title: "Someone else's", author_id: Ash.UUID.generate()})

      assert {:ok, updated} = update_title(item, actor)
      assert updated.title == "Updated"
    end

    test "permission order does not change the outcome (blanket listed first)" do
      actor = actor_with_perms(["item:*:*:always", "item:*:update:own"])
      item = create_item!(%{title: "Someone else's", author_id: Ash.UUID.generate()})

      assert {:ok, _} = update_title(item, actor)
    end

    test "destroy outside the narrow scope succeeds via the blanket grant" do
      actor = actor_with_perms(["item:*:destroy:own", "item:*:*:always"])
      item = create_item!(%{title: "Someone else's", author_id: Ash.UUID.generate()})

      assert :ok =
               item
               |> Ash.Changeset.for_destroy(:destroy)
               |> Ash.destroy(actor: actor)
    end

    test "create outside the narrow scope succeeds via the blanket grant" do
      actor = actor_with_perms(["item:*:create:own", "item:*:*:always"])

      assert {:ok, _} =
               BulkItem
               |> Ash.Changeset.for_create(:create, %{
                 title: "For someone else",
                 author_id: Ash.UUID.generate()
               })
               |> Ash.create(actor: actor)
    end

    test "union spans evaluation strategies: failing DB-fallback scope + passing in-memory blanket" do
      # :team_member needs a DB query (exists()); the actor has no membership,
      # so that grant fails — the :always grant must still authorize.
      actor = actor_with_perms(["item:*:update:team_member", "item:*:*:always"])
      item = create_item!(%{title: "No team", author_id: Ash.UUID.generate()})

      assert {:ok, _} = update_title(item, actor)
    end
  end

  describe "union does not weaken enforcement" do
    test "still forbidden when no grant's scope passes" do
      actor = actor_with_perms(["item:*:update:own", "item:*:read:always"])
      item = create_item!(%{title: "Not mine", author_id: Ash.UUID.generate()})

      assert {:error, %Ash.Error.Forbidden{}} = update_title(item, actor)
    end

    test "deny still wins over every allow in the union" do
      actor_id = Ash.UUID.generate()
      actor = actor_with_perms(["item:*:*:always", "!item:*:update:always"], actor_id)
      item = create_item!(%{title: "Mine", author_id: actor_id})

      assert {:error, %Ash.Error.Forbidden{}} = update_title(item, actor)
    end
  end

  describe "write: false scopes in a union" do
    defp create_frozen_item! do
      FrozenItem
      |> Ash.Changeset.for_create(:create, %{title: "Anything"}, authorize?: false)
      |> Ash.create!(authorize?: false)
    end

    test "write: false no longer hard-blocks when another grant passes (use ! deny for hard blocks)" do
      actor = actor_with_perms(["frozen_item:*:update:frozen", "frozen_item:*:*:always"])
      item = create_frozen_item!()

      assert {:ok, _} =
               item
               |> Ash.Changeset.for_update(:update, %{title: "Updated"})
               |> Ash.update(actor: actor)
    end

    test "write: false alone still forbids" do
      actor = actor_with_perms(["frozen_item:*:update:frozen", "frozen_item:*:read:always"])
      item = create_frozen_item!()

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{title: "Updated"})
               |> Ash.update(actor: actor)
    end
  end
end

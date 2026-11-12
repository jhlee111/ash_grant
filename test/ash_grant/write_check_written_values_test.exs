defmodule AshGrant.WrittenValues.Item do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.WrittenValues.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("bulk_test_items")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context -> Map.get(actor || %{}, :permissions, []) end)
    resource_name("written_item")

    scope(:own, expr(author_id == ^actor(:id)))
    scope(:own_ref, expr(^ref(:author_id) == ^actor(:id)))
    scope(:team_member, [], expr(exists(team.memberships, user_id == ^actor(:id))))

    scope(
      :own_or_team,
      [],
      expr(author_id == ^actor(:id) or exists(team.memberships, user_id == ^actor(:id)))
    )

    scope(:title_ab, expr(title in ["a", "b"]))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :team, AshGrant.Test.BulkTeam do
      public?(true)
      allow_nil?(true)
      attribute_writable?(true)
    end
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
    defaults([:read, :destroy, create: :*, update: :*])

    update :move do
      require_atomic?(false)
      argument(:new_team, :uuid, allow_nil?: false)
      change(manage_relationship(:new_team, :team, type: :append_and_remove))
    end

    update :reassign do
      require_atomic?(false)
      argument(:new_author, :uuid, allow_nil?: false)
      change(set_attribute(:author_id, arg(:new_author)))
    end

    destroy :hand_off do
      require_atomic?(false)
      soft?(true)
      accept([:author_id])
    end
  end
end

defmodule AshGrant.WrittenValues.KeyedItem do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.WrittenValues.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("bulk_test_items")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context -> Map.get(actor || %{}, :permissions, []) end)
    resource_name("keyed_item")
    instance_key(:author_id)
    scope(:always, true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true)
  end

  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if(AshGrant.check())
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.WrittenValues.Refund do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.WrittenValues.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ets do
    private?(true)
  end

  ash_grant do
    resolver(fn actor, _context -> Map.get(actor || %{}, :permissions, []) end)
    resource_name("written_refund")
    scope(:at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids)))
    resolve_argument(:center_id, from_path: [:order, :center_id])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:amount, :integer, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to :order, AshGrant.Test.Auth.Order do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if(AshGrant.check())
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:amount, :order_id])
    end

    update :update do
      accept([:amount, :order_id])
      require_atomic?(false)
    end
  end
end

defmodule AshGrant.WrittenValues.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGrant.WrittenValues.Item)
    resource(AshGrant.WrittenValues.KeyedItem)
    resource(AshGrant.WrittenValues.Refund)
  end
end

defmodule AshGrant.WriteCheckWrittenValuesTest do
  @moduledoc """
  Regression tests for how `AshGrant.Check` reads the values an update writes:
  `^ref/1` scopes, managed relationships, `set_attribute` from an argument,
  `resolve_argument` scopes, grants combined across the stored and written
  record, mixed attribute/relationship `or` scopes, atomic bulk updates, the
  written instance key, a tenant attribute move, and destroys.
  """
  use AshGrant.DataCase, async: true

  require Ash.Expr

  alias AshGrant.Test.BulkMembership
  alias AshGrant.Test.BulkTeam
  alias AshGrant.WrittenValues.Item
  alias AshGrant.WrittenValues.KeyedItem
  alias AshGrant.WrittenValues.Refund

  defp item!(attrs),
    do: Item |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false)

  defp team!(name),
    do:
      BulkTeam
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create!(authorize?: false)

  defp member!(team, user_id) do
    BulkMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: user_id})
    |> Ash.create!(authorize?: false)
  end

  defp stored(item), do: Ash.get!(Item, item.id, authorize?: false)

  defp actor(id, permissions), do: %{id: id, permissions: permissions}

  setup do
    %{me: Ash.UUID.generate(), other: Ash.UUID.generate()}
  end

  describe "scopes the check reads the written value for" do
    test "a scope written with ^ref/1", ctx do
      item = item!(%{title: "a", author_id: ctx.me})

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{author_id: ctx.other})
               |> Ash.update(actor: actor(ctx.me, ["written_item:*:update:own_ref"]))

      assert stored(item).author_id == ctx.me
    end

    test "a belongs_to moved through manage_relationship fails closed", ctx do
      mine = team!("mine")
      member!(mine, ctx.me)
      item = item!(%{title: "a", team_id: mine.id})

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:move, %{new_team: team!("other").id})
               |> Ash.update(actor: actor(ctx.me, ["written_item:*:move:team_member"]))

      assert stored(item).team_id == mine.id
    end

    test "set_attribute from an argument is checked like accepted input", ctx do
      item = item!(%{title: "a", author_id: ctx.me})
      actor = actor(ctx.me, ["written_item:*:reassign:own"])

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:reassign, %{new_author: ctx.other})
               |> Ash.update(actor: actor)

      assert {:ok, _} =
               item
               |> Ash.Changeset.for_update(:reassign, %{new_author: ctx.me})
               |> Ash.update(actor: actor)
    end

    test "Ash.update/3 with params takes the atomic path and is checked", ctx do
      item = item!(%{title: "a", author_id: ctx.me})
      actor = actor(ctx.me, ["written_item:*:update:own"])

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(item, %{author_id: ctx.other}, actor: actor)

      assert stored(item).author_id == ctx.me
    end

    test "a string attribute changed within the scope passes", ctx do
      item = item!(%{title: "a"})
      actor = actor(ctx.me, ["written_item:*:update:title_ab"])

      assert {:ok, %{title: "b"}} = Ash.update(item, %{title: "b"}, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.update(item, %{title: "c"}, actor: actor)
    end
  end

  describe "grants combine across the stored and the written record" do
    test "the stored record under one grant, the written record under another", ctx do
      mine = team!("mine")
      member!(mine, ctx.me)
      item = item!(%{title: "a", author_id: ctx.me})

      actor =
        actor(ctx.me, ["written_item:*:update:own", "written_item:*:update:team_member"])

      assert {:ok, _} =
               item
               |> Ash.Changeset.for_update(:update, %{author_id: ctx.other, team_id: mine.id})
               |> Ash.update(actor: actor)
    end

    test "neither grant admits the written record", ctx do
      item = item!(%{title: "a", author_id: ctx.me})

      actor =
        actor(ctx.me, ["written_item:*:update:own", "written_item:*:update:team_member"])

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{author_id: ctx.other})
               |> Ash.update(actor: actor)
    end
  end

  describe "an `or` scope mixing an attribute and a relationship" do
    setup ctx do
      %{actor: actor(ctx.me, ["written_item:*:update:own_or_team"])}
    end

    test "changing the FK passes while the owner still matches", ctx do
      item = item!(%{title: "a", author_id: ctx.me})

      assert {:ok, _} =
               item
               |> Ash.Changeset.for_update(:update, %{team_id: team!("other").id})
               |> Ash.update(actor: ctx.actor)
    end

    test "giving the record away passes while the written team still matches", ctx do
      mine = team!("mine")
      member!(mine, ctx.me)
      item = item!(%{title: "a", author_id: ctx.me, team_id: mine.id})

      assert {:ok, _} =
               item
               |> Ash.Changeset.for_update(:update, %{author_id: ctx.other})
               |> Ash.update(actor: ctx.actor)
    end

    test "leaving both branches is forbidden", ctx do
      mine = team!("mine")
      member!(mine, ctx.me)
      item = item!(%{title: "a", author_id: ctx.me, team_id: mine.id})

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{
                 author_id: ctx.other,
                 team_id: team!("other").id
               })
               |> Ash.update(actor: ctx.actor)
    end

    test "a create is decided over the whole `or`", ctx do
      assert {:ok, _} =
               Item
               |> Ash.Changeset.for_create(:create, %{title: "a", author_id: ctx.me})
               |> Ash.create(actor: actor(ctx.me, ["written_item:*:create:own_or_team"]))
    end
  end

  describe "resolve_argument scopes" do
    setup ctx do
      order = fn center ->
        AshGrant.Test.Auth.Order
        |> Ash.Changeset.for_create(:create, %{center_id: center})
        |> Ash.create!(authorize?: false)
      end

      my_center = Ash.UUID.generate()
      mine = order.(my_center)

      refund =
        Refund
        |> Ash.Changeset.for_create(:create, %{amount: 1, order_id: mine.id})
        |> Ash.create!(authorize?: false)

      actor = %{
        id: ctx.me,
        own_org_unit_ids: [my_center],
        permissions: ["written_refund:*:update:at_own_unit"]
      }

      %{actor: actor, refund: refund, order: order, my_center: my_center}
    end

    test "moving to an order in another center is forbidden", ctx do
      theirs = ctx.order.(Ash.UUID.generate())

      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.refund
               |> Ash.Changeset.for_update(:update, %{order_id: theirs.id}, actor: ctx.actor)
               |> Ash.update()
    end

    test "moving to another order in the same center passes", ctx do
      also_mine = ctx.order.(ctx.my_center)

      assert {:ok, _} =
               ctx.refund
               |> Ash.Changeset.for_update(:update, %{order_id: also_mine.id}, actor: ctx.actor)
               |> Ash.update()
    end

    test "an update that leaves the order alone passes", ctx do
      assert {:ok, %{amount: 2}} =
               ctx.refund
               |> Ash.Changeset.for_update(:update, %{amount: 2}, actor: ctx.actor)
               |> Ash.update()
    end
  end

  describe "bulk updates on the default (atomic) strategy" do
    test "cannot move records out of the scope", ctx do
      item = item!(%{title: "a", author_id: ctx.me})
      actor = actor(ctx.me, ["written_item:*:update:own", "written_item:*:read:own"])

      Item
      |> Ash.Query.for_read(:read)
      |> Ash.bulk_update(:update, %{author_id: ctx.other}, actor: actor, return_errors?: true)

      assert stored(item).author_id == ctx.me
    end

    test "cannot apply an atomic expression to a scoped attribute", ctx do
      item = item!(%{title: "a", author_id: ctx.me})
      actor = actor(ctx.me, ["written_item:*:update:own", "written_item:*:read:own"])

      Item
      |> Ash.Query.for_read(:read)
      |> Ash.bulk_update(:update, %{},
        actor: actor,
        return_errors?: true,
        atomic_update: %{author_id: Ash.Expr.expr(fragment("gen_random_uuid()"))}
      )

      assert stored(item).author_id == ctx.me
    end
  end

  describe "the written instance key" do
    setup do
      locked = Ash.UUID.generate()

      item =
        KeyedItem
        |> Ash.Changeset.for_create(:create, %{title: "a", author_id: Ash.UUID.generate()})
        |> Ash.create!(authorize?: false)

      %{
        item: item,
        locked: locked,
        actor: %{permissions: ["keyed_item:*:update:always", "!keyed_item:#{locked}:update:"]}
      }
    end

    test "cannot be set to a denied id", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(ctx.item, %{author_id: ctx.locked}, actor: ctx.actor)

      assert {:ok, _} = Ash.update(ctx.item, %{author_id: Ash.UUID.generate()}, actor: ctx.actor)
    end

    test "an atomic key the check cannot compute fails closed", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.item
               |> Ash.Changeset.for_update(:update, %{})
               |> Ash.Changeset.atomic_update(
                 :author_id,
                 Ash.Expr.expr(fragment("gen_random_uuid()"))
               )
               |> Ash.update(actor: ctx.actor)
    end
  end

  describe "tenant attribute" do
    test "a same_tenant grant cannot move the record to another tenant" do
      tenant = Ash.UUID.generate()

      post =
        AshGrant.Test.TenantPost
        |> Ash.Changeset.for_create(:create, %{title: "t", tenant_id: tenant}, tenant: tenant)
        |> Ash.create!(authorize?: false)

      actor = %{id: Ash.UUID.generate(), permissions: ["tenant_post:*:update:same_tenant"]}

      assert {:error, %Ash.Error.Forbidden{}} =
               post
               |> Ash.Changeset.for_update(:update, %{tenant_id: Ash.UUID.generate()},
                 tenant: tenant
               )
               |> Ash.update(actor: actor)

      assert {:ok, _} =
               post
               |> Ash.Changeset.for_update(:update, %{title: "renamed"}, tenant: tenant)
               |> Ash.update(actor: actor)
    end
  end

  describe "destroy" do
    test "a hard destroy under the scope passes", ctx do
      item = item!(%{title: "a", author_id: ctx.me})
      assert :ok = Ash.destroy(item, actor: actor(ctx.me, ["written_item:*:destroy:own"]))
    end

    test "a soft destroy cannot write a value outside the scope", ctx do
      item = item!(%{title: "a", author_id: ctx.me})
      actor = actor(ctx.me, ["written_item:*:hand_off:own"])

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_destroy(:hand_off, %{author_id: ctx.other})
               |> Ash.destroy(actor: actor)

      assert stored(item).author_id == ctx.me
    end
  end
end

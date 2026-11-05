defmodule AshGrant.ResolveArgumentInjectionTest do
  @moduledoc """
  A `resolve_argument` value is authorization input, so a caller must never
  be able to supply it. Each spoof case below passes a `center_id` the actor
  owns for a record whose real center the actor does not own, along a path
  where `AshGrant.Changes.ResolveArgument` does not resolve the argument.
  """
  use ExUnit.Case, async: false

  alias AshGrant.Test.Auth.{Order, RefundDsl}

  defmodule LocalOrder do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.ResolveArgumentInjectionTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:center_id, :uuid, public?: true, allow_nil?: false)
    end

    actions do
      defaults([:read, :destroy, create: :*])
    end
  end

  defmodule NullableRefund do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.ResolveArgumentInjectionTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, _context -> Map.get(actor || %{}, :permissions, []) end)
      resource_name("nullable_refund")
      scope(:at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids)))
      resolve_argument(:center_id, from_path: [:order, :center_id])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:amount, :integer, public?: true, allow_nil?: false)
    end

    relationships do
      belongs_to :order, AshGrant.ResolveArgumentInjectionTest.LocalOrder do
        public?(true)
        allow_nil?(true)
        attribute_writable?(true)
      end
    end

    policies do
      policy action_type([:create, :update, :destroy]) do
        authorize_if(AshGrant.check())
      end

      policy action_type(:read) do
        authorize_if(always())
      end
    end

    actions do
      defaults([:read])

      create :create do
        accept([:amount, :order_id])
      end
    end
  end

  defmodule OverrideRefund do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.ResolveArgumentInjectionTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, _context -> Map.get(actor || %{}, :permissions, []) end)
      resource_name("override_refund")
      scope(:at_own_unit, expr(^arg(:center_id) in ^actor(:own_org_unit_ids)))
      resolve_argument(:center_id, from_path: [:order, :center_id])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:amount, :integer, public?: true, allow_nil?: false)
    end

    relationships do
      belongs_to :order, AshGrant.ResolveArgumentInjectionTest.LocalOrder do
        public?(true)
        allow_nil?(false)
        attribute_writable?(true)
      end
    end

    policies do
      policy action_type([:create, :update, :destroy]) do
        authorize_if(AshGrant.check(resource: "refund"))
      end

      policy action_type(:read) do
        authorize_if(always())
      end
    end

    actions do
      defaults([:read])

      create :create do
        accept([:amount, :order_id])
      end

      update :update do
        accept([:amount])
        require_atomic?(false)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshGrant.ResolveArgumentInjectionTest.LocalOrder)
      resource(AshGrant.ResolveArgumentInjectionTest.NullableRefund)
      resource(AshGrant.ResolveArgumentInjectionTest.OverrideRefund)
    end
  end

  setup do
    RefundDsl |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    Order |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    mine = Ash.UUID.generate()
    theirs = Ash.UUID.generate()
    actor_id = Ash.UUID.generate()

    actor = fn perm ->
      %{id: actor_id, permissions: [perm], own_org_unit_ids: [mine]}
    end

    {:ok, mine: mine, theirs: theirs, actor_id: actor_id, actor: actor}
  end

  defp create_order!(resource \\ Order, center_id) do
    Ash.create!(resource, %{center_id: center_id}, action: :create, authorize?: false)
  end

  defp create_refund!(author_id, order_id) do
    Ash.create!(RefundDsl, %{author_id: author_id, order_id: order_id, amount: 100},
      action: :create,
      authorize?: false
    )
  end

  describe "injected argument" do
    test "is not public on any targeted action" do
      for action <- [:create, :update, :destroy] do
        argument =
          RefundDsl
          |> Ash.Resource.Info.action(action)
          |> Map.fetch!(:arguments)
          |> Enum.find(&(&1.name == :center_id))

        assert argument.public? == false, "#{action} exposes :center_id as public input"
      end
    end
  end

  describe "legitimate actor" do
    test "is allowed when the record's real center is the actor's", ctx do
      order = create_order!(ctx.mine)
      refund = create_refund!(ctx.actor_id, order.id)
      actor = ctx.actor.("refund_dsl:*:update:at_own_unit")

      assert {:ok, %{amount: 5}} =
               refund
               |> Ash.Changeset.for_update(:update, %{amount: 5}, actor: actor)
               |> Ash.update(actor: actor)
    end
  end

  describe "caller-supplied center_id" do
    test "is ignored when the actor is passed only to Ash.update", ctx do
      order = create_order!(ctx.theirs)
      refund = create_refund!(ctx.actor_id, order.id)
      actor = ctx.actor.("refund_dsl:*:update:at_own_unit")

      assert {:error, %Ash.Error.Forbidden{}} =
               refund
               |> Ash.Changeset.for_update(:update, %{amount: 5, center_id: ctx.mine})
               |> Ash.update(actor: actor)
    end

    test "is ignored when the parent record has been deleted", ctx do
      order = create_order!(ctx.theirs)
      refund = create_refund!(ctx.actor_id, order.id)
      Ash.destroy!(order, authorize?: false)
      actor = ctx.actor.("refund_dsl:*:update:at_own_unit")

      assert {:error, %Ash.Error.Forbidden{}} =
               refund
               |> Ash.Changeset.for_update(:update, %{amount: 5, center_id: ctx.mine},
                 actor: actor
               )
               |> Ash.update(actor: actor)
    end

    test "is ignored on create when order_id does not exist", ctx do
      actor = ctx.actor.("refund_dsl:*:create:at_own_unit")

      assert {:error, %Ash.Error.Forbidden{}} =
               RefundDsl
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   author_id: ctx.actor_id,
                   order_id: Ash.UUID.generate(),
                   amount: 5,
                   center_id: ctx.mine
                 },
                 actor: actor
               )
               |> Ash.create(actor: actor)
    end

    test "is ignored on create when a nullable foreign key is nil", ctx do
      actor = ctx.actor.("nullable_refund:*:create:at_own_unit")

      assert {:error, %Ash.Error.Forbidden{}} =
               NullableRefund
               |> Ash.Changeset.for_create(:create, %{amount: 5, center_id: ctx.mine},
                 actor: actor
               )
               |> Ash.create(actor: actor)
    end

    test "is ignored when the policy uses a resource: override", ctx do
      order = create_order!(LocalOrder, ctx.theirs)

      refund =
        Ash.create!(OverrideRefund, %{amount: 1, order_id: order.id},
          action: :create,
          authorize?: false
        )

      actor = ctx.actor.("refund:*:update:at_own_unit")

      assert {:error, %Ash.Error.Forbidden{}} =
               refund
               |> Ash.Changeset.for_update(:update, %{amount: 5, center_id: ctx.mine},
                 actor: actor
               )
               |> Ash.update(actor: actor)
    end

    test "resource: override still allows the record's real center", ctx do
      order = create_order!(LocalOrder, ctx.mine)

      refund =
        Ash.create!(OverrideRefund, %{amount: 1, order_id: order.id},
          action: :create,
          authorize?: false
        )

      actor = ctx.actor.("refund:*:update:at_own_unit")

      assert {:ok, %{amount: 5}} =
               refund
               |> Ash.Changeset.for_update(:update, %{amount: 5}, actor: actor)
               |> Ash.update(actor: actor)
    end
  end
end

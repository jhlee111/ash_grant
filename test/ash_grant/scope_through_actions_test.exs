defmodule AshGrant.ScopeThroughActionsTest do
  @moduledoc """
  Regression for #140: `scope_through ... actions: [...]` must be enforced by
  `Introspect.can?/4` and the `CanPerform` calculation, not just by
  `AshGrant.Check`/`FilterCheck`.
  """
  use ExUnit.Case, async: true

  defmodule ReadOnlyChild do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.ScopeThroughActionsTest.ReadOnlyChildDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshGrant]

    ash_grant do
      resolver(fn actor, _context ->
        case actor do
          %{permissions: perms} -> perms
          _ -> []
        end
      end)

      resource_name("read_only_child")

      scope(:always, true)
      scope_through(:post, actions: [:read])

      can_perform_actions([:update])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:post_id, :uuid, public?: true)
    end

    relationships do
      belongs_to :post, AshGrant.Test.Post do
        public?(true)
        define_attribute?(false)
      end
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule ReadOnlyChildDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshGrant.ScopeThroughActionsTest.ReadOnlyChild)
    end
  end

  describe "Info.scope_through_allows_action?/3" do
    test "honors the actions filter" do
      st = %AshGrant.Dsl.ScopeThrough{
        relationship: :post,
        resource: nil,
        actions: [:read, :update]
      }

      assert AshGrant.Info.scope_through_allows_action?(st, "read", :read)
      assert AshGrant.Info.scope_through_allows_action?(st, "update", :update)
      refute AshGrant.Info.scope_through_allows_action?(st, "destroy", :destroy)
    end

    test "allows every action when actions is nil" do
      st = %AshGrant.Dsl.ScopeThrough{relationship: :post, resource: nil, actions: nil}

      assert AshGrant.Info.scope_through_allows_action?(st, "read", :read)
      assert AshGrant.Info.scope_through_allows_action?(st, "destroy", :destroy)
    end

    test "fails closed when the action type is unknown" do
      st = %AshGrant.Dsl.ScopeThrough{relationship: :post, resource: nil, actions: [:read]}

      refute AshGrant.Info.scope_through_allows_action?(st, "read", nil)
    end
  end

  describe "Introspect.can?/4 honors the actions filter" do
    test "read is allowed via scope_through, update is not" do
      post_id = Ash.UUID.generate()

      actor = %{
        id: Ash.UUID.generate(),
        permissions: ["post:#{post_id}:read:", "post:#{post_id}:update:"]
      }

      assert {:allow, %{via: :scope_through}} =
               AshGrant.Introspect.can?(ReadOnlyChild, :read, actor)

      assert {:deny, %{reason: :no_permission}} =
               AshGrant.Introspect.can?(ReadOnlyChild, :update, actor)
    end
  end

  describe "CanPerform honors the actions filter" do
    test "can_update? is false when update is excluded by actions: [:read]" do
      post_id = Ash.UUID.generate()
      actor = %{id: Ash.UUID.generate(), permissions: ["post:#{post_id}:update:"]}

      child =
        ReadOnlyChild
        |> Ash.Changeset.for_create(:create, %{post_id: post_id}, authorize?: false)
        |> Ash.create!()

      [loaded] =
        ReadOnlyChild
        |> Ash.Query.for_read(:read)
        |> Ash.Query.load([:can_update?])
        |> Ash.read!(actor: actor)

      assert loaded.id == child.id
      refute loaded.can_update?
    end
  end
end

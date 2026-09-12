defmodule AshGrant.TrueScopeUnionTest do
  @moduledoc """
  A scope whose filter is `true` must absorb an OR union with any other matching
  scope, whatever that scope is NAMED
  ([issue #149](https://github.com/jhlee111/ash_grant/issues/149)).

  Only `always`/`all`/`global` short-circuit by name, so a scope declared
  `scope(:x, true)` was dropped by `Enum.reject(&(&1 == true))` before the
  remaining filters were OR-combined: `true OR filter` became `filter`. The
  three OR sites are the read path (`FilterCheck`), field visibility
  (`FieldFilterCheck`) and the UI answer (`CanPerform`); each has an arm here.

  Fails closed (under-grant), which is why a control naming `always` — same
  `true` filter, different name — accompanies each arm.
  """
  use ExUnit.Case, async: true

  defmodule Doc do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.TrueScopeUnionTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, _context -> (actor && Map.get(actor, :permissions)) || [] end)
      resource_name("true_scope_doc")
      default_policies(true)
      can_perform_actions([:update])

      scope(:always, true)
      scope(:everything, true)
      scope(:mine, expr(owner_id == ^actor(:id)))
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:owner_id, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule FieldDoc do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.TrueScopeUnionTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, _context -> (actor && Map.get(actor, :permissions)) || [] end)
      resource_name("true_scope_field_doc")
      default_policies(true)
      default_field_policies(true)

      scope(:always, true)
      scope(:everything, true)
      scope(:mine, expr(owner_id == ^actor(:id)))

      field_group(:public, [:title])
      field_group(:sensitive, [:secret], inherits: [:public])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:secret, :string, public?: true)
      attribute(:owner_id, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshGrant.TrueScopeUnionTest.Doc)
      resource(AshGrant.TrueScopeUnionTest.FieldDoc)
    end
  end

  alias AshGrant.FieldFilterCheck
  alias AshGrant.TrueScopeUnionTest.Doc
  alias AshGrant.TrueScopeUnionTest.FieldDoc

  @me "u1"
  @them "u2"

  # One row per owner, actor is @me. @them is reachable only through a scope that
  # admits every row, so its presence separates `true OR mine` from `mine`.
  setup do
    Ash.create!(Doc, %{title: "mine", owner_id: @me}, authorize?: false)
    Ash.create!(Doc, %{title: "theirs", owner_id: @them}, authorize?: false)

    Ash.create!(FieldDoc, %{title: "mine", secret: "s-mine", owner_id: @me}, authorize?: false)

    Ash.create!(FieldDoc, %{title: "theirs", secret: "s-theirs", owner_id: @them},
      authorize?: false
    )

    :ok
  end

  defp actor(permissions), do: %{id: @me, permissions: permissions}

  defp readable_owner_ids(permissions) do
    Doc
    |> Ash.Query.for_read(:read, %{}, actor: actor(permissions))
    |> Ash.read!()
    |> Enum.map(& &1.owner_id)
    |> Enum.sort()
  end

  # `:read` is the action_type FieldFilterCheck.do_filter/3 passes in production.
  defp visibility(permissions, group) do
    FieldFilterCheck.field_visibility_filter(permissions, FieldDoc, "read", group, :read)
  end

  # Rows come from the `always` NAME (it short-circuits before the code under
  # test) plus the :public group, so only the :sensitive grants vary here.
  defp secret_on_their_row(sensitive_permissions) do
    permissions = ["true_scope_field_doc:*:read:always:public" | sensitive_permissions]

    FieldDoc
    |> Ash.Query.for_read(:read, %{}, actor: actor(permissions))
    |> Ash.read!()
    |> Enum.find(&(&1.owner_id == @them))
    |> Map.fetch!(:secret)
  end

  # The CanPerform arms grant read through the `always` NAME so the row is
  # fetched by a path this defect cannot narrow; only the update grants vary.
  defp can_update_on_their_record?(update_permissions) do
    permissions = ["true_scope_doc:*:read:always" | update_permissions]

    Doc
    |> Ash.Query.for_read(:read, %{}, actor: actor(permissions))
    |> Ash.Query.load(:can_update?)
    |> Ash.read!()
    |> Enum.find(&(&1.owner_id == @them))
    |> Map.fetch!(:can_update?)
  end

  describe "read path (FilterCheck)" do
    test "a scope declared true, held alone, reads every row (control)" do
      assert readable_owner_ids(["true_scope_doc:*:read:everything"]) == [@me, @them]
    end

    test "a narrowing scope, held alone, reads only the actor's row (control)" do
      assert readable_owner_ids(["true_scope_doc:*:read:mine"]) == [@me]
    end

    test "the scope NAMED always plus a narrowing scope reads every row (control)" do
      assert readable_owner_ids(["true_scope_doc:*:read:always", "true_scope_doc:*:read:mine"]) ==
               [@me, @them]
    end

    test "a scope declared true plus a narrowing scope reads every row" do
      assert readable_owner_ids([
               "true_scope_doc:*:read:everything",
               "true_scope_doc:*:read:mine"
             ]) == [@me, @them]
    end
  end

  describe "field visibility (FieldFilterCheck)" do
    test "a scope declared true, held alone, shows the group on every row (control)" do
      assert visibility(["true_scope_field_doc:*:read:everything:sensitive"], :sensitive) == true
    end

    test "the scope NAMED always plus a narrowing scope shows the group on every row (control)" do
      assert visibility(
               [
                 "true_scope_field_doc:*:read:always:sensitive",
                 "true_scope_field_doc:*:read:mine:sensitive"
               ],
               :sensitive
             ) == true
    end

    test "a scope declared true plus a narrowing scope shows the group on every row" do
      assert visibility(
               [
                 "true_scope_field_doc:*:read:everything:sensitive",
                 "true_scope_field_doc:*:read:mine:sensitive"
               ],
               :sensitive
             ) == true
    end

    test "a narrowing scope alone forbids the group on another owner's row (control)" do
      assert %Ash.ForbiddenField{} =
               secret_on_their_row(["true_scope_field_doc:*:read:mine:sensitive"])
    end

    test "a scope declared true plus a narrowing scope renders the group on another owner's row" do
      assert secret_on_their_row([
               "true_scope_field_doc:*:read:everything:sensitive",
               "true_scope_field_doc:*:read:mine:sensitive"
             ]) == "s-theirs"
    end
  end

  describe "per-record answer (CanPerform)" do
    test "a scope declared true, held alone, answers true on another owner's record (control)" do
      assert can_update_on_their_record?(["true_scope_doc:*:update:everything"])
    end

    test "the scope NAMED always plus a narrowing scope answers true on another owner's record (control)" do
      assert can_update_on_their_record?([
               "true_scope_doc:*:update:always",
               "true_scope_doc:*:update:mine"
             ])
    end

    test "a scope declared true plus a narrowing scope answers true on another owner's record" do
      assert can_update_on_their_record?([
               "true_scope_doc:*:update:everything",
               "true_scope_doc:*:update:mine"
             ])
    end
  end
end

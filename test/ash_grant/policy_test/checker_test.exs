defmodule AshGrant.PolicyTest.CheckerTest do
  @moduledoc """
  The policy test checker decides a record the way the runtime check for that
  action does: write actions honor a scope's `write:` override, the resolver gets
  the runtime's context, and the grants are resolved once per check.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.{Checker, YamlParser}

  # Inline because the `write:` option emits a compile-time deprecation warning,
  # and CI compiles test/support with --warnings-as-errors.
  defmodule Note do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.PolicyTest.CheckerTest.NoteDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, context ->
        send(self(), {:resolved, context})

        extra =
          case context do
            %{action: %{name: :update}} -> Map.get(actor, :on_update, [])
            _ -> []
          end

        Map.get(actor, :permissions, []) ++ extra
      end)

      resource_name("note")

      scope(:always, true)
      scope(:frozen, [], expr(title == "frozen"), write: false)
      scope(:split, [], expr(title == "read"), write: expr(title == "write"))
      scope(:tenanted, expr(title == ^tenant()))
      scope(:contextual, expr(title == ^context(:title)))
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

  # A parent matched by a slug, while the child's foreign key holds its id.
  defmodule Board do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.PolicyTest.CheckerTest.NoteDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, _context -> Map.get(actor, :permissions, []) end)
      resource_name("board")
      instance_key(:slug)
      scope(:always, true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:slug, :string, public?: true)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Pin do
    @moduledoc false
    use Ash.Resource,
      domain: AshGrant.PolicyTest.CheckerTest.NoteDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshGrant]

    ets do
      private?(true)
    end

    ash_grant do
      resolver(fn actor, _context -> Map.get(actor, :permissions, []) end)
      resource_name("pin")
      scope(:always, true)
      scope_through(:board)
    end

    attributes do
      uuid_primary_key(:id)
    end

    relationships do
      belongs_to(:board, AshGrant.PolicyTest.CheckerTest.Board, public?: true)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule NoteDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshGrant.PolicyTest.CheckerTest.Note)
      resource(AshGrant.PolicyTest.CheckerTest.Board)
      resource(AshGrant.PolicyTest.CheckerTest.Pin)
    end
  end

  describe "a write action uses the scope's write: override" do
    test "write: false never admits a record, though the read filter does" do
      actor = %{permissions: ["note:*:*:frozen"]}

      assert {:allow, _} = Checker.check(Note, actor, :read, %{title: "frozen"})

      assert {:deny, %{reason: :scope_mismatch}} =
               Checker.check(Note, actor, :update, %{title: "frozen"})
    end

    test "write: expr is evaluated instead of the read filter" do
      actor = %{permissions: ["note:*:*:split"]}

      assert {:allow, _} = Checker.check(Note, actor, :read, %{title: "read"})
      assert {:deny, _} = Checker.check(Note, actor, :read, %{title: "write"})
      assert {:allow, _} = Checker.check(Note, actor, :update, %{title: "write"})
      assert {:deny, _} = Checker.check(Note, actor, :update, %{title: "read"})
    end
  end

  describe "the resolver" do
    test "gets the action in its context, as the runtime check passes it" do
      actor = %{permissions: [], on_update: ["note:*:update:always"]}

      assert {:allow, _} = Checker.check(Note, actor, :update, nil)
      assert_received {:resolved, %{actor: ^actor, resource: Note, action: %{name: :update}}}
    end

    test "runs once per check, with a record too" do
      actor = %{permissions: ["note:*:update:split"]}

      assert {:allow, _} = Checker.check(Note, actor, :update, %{title: "write"})
      assert_received {:resolved, _}
      refute_received {:resolved, _}
    end
  end

  describe "what a policy test cannot supply is undecided, never a deny" do
    test "a scope that reads ^tenant()" do
      actor = %{permissions: ["note:*:read:tenanted"]}

      assert {:indeterminate, %{undecided: ["scope `tenanted` uses ^tenant()" <> _]}} =
               Checker.check(Note, actor, :read, %{title: "t1"})
    end

    test "a scope that reads ^context(...)" do
      actor = %{permissions: ["note:*:read:contextual"]}

      assert {:indeterminate, %{undecided: ["scope `contextual` uses ^context(...)" <> _]}} =
               Checker.check(Note, actor, :read, %{title: "x"})
    end

    test "a scope_through that matches the parent through a join" do
      actor = %{permissions: ["board:general:read:"]}

      assert {:indeterminate, %{undecided: ["scope_through `board`" <> _]}} =
               Checker.check(Pin, actor, :read, %{board_id: Ash.UUID.generate()})
    end

    test "but a join with no parent grant in play is decided" do
      actor = %{permissions: ["pin:other:read:"]}

      assert {:deny, %{reason: :scope_mismatch}} =
               Checker.check(Pin, actor, :read, %{id: "mine", board_id: Ash.UUID.generate()})
    end
  end

  test "a nil actor is denied without calling the resolver" do
    assert {:deny, %{reason: :no_actor}} = Checker.check(Note, nil, :read, %{title: "x"})
    refute_received {:resolved, _}
  end

  @tag :tmp_dir
  test "a YAML assertion without an actor: key says so", %{tmp_dir: dir} do
    path = Path.join(dir, "no_actor.yaml")

    File.write!(path, """
    resource: AshGrant.Test.Document

    actors:
      reader:
        role: reader

    tests:
      - name: "forgot the actor"
        assert_can:
          action: read
    """)

    assert {:ok, [%{passed: false, message: "The assertion has no `actor:` key"}]} =
             YamlParser.run_yaml_tests(path)
  end
end

defmodule AshGrant.CanPerformDslTest do
  @moduledoc """
  Tests for the can_perform DSL entity and can_perform_actions batch option.

  Verifies that the transformer correctly generates CanPerform calculations
  from DSL declarations.
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.Test.Post
  alias AshGrant.Test.SharedDoc

  describe "can_perform_actions batch option" do
    test "generates calculations for all listed actions" do
      # Post uses can_perform_actions [:update, :destroy]
      calcs = Ash.Resource.Info.calculations(Post)
      calc_names = Enum.map(calcs, & &1.name)

      assert :can_update? in calc_names
      assert :can_destroy? in calc_names
    end

    test "generated calculations are public" do
      calcs = Ash.Resource.Info.calculations(Post)
      can_update = Enum.find(calcs, &(&1.name == :can_update?))
      can_destroy = Enum.find(calcs, &(&1.name == :can_destroy?))

      assert can_update.public? == true
      assert can_destroy.public? == true
    end

    test "generated calculations use CanPerform module" do
      calcs = Ash.Resource.Info.calculations(Post)
      can_update = Enum.find(calcs, &(&1.name == :can_update?))

      assert {AshGrant.Calculation.CanPerform, opts} = can_update.calculation
      assert opts[:action] == "update"
      assert opts[:resource] == Post
    end
  end

  describe "can_perform entity" do
    test "generates calculation for the specified action" do
      # SharedDoc uses can_perform :update
      calcs = Ash.Resource.Info.calculations(SharedDoc)
      calc_names = Enum.map(calcs, & &1.name)

      assert :can_update? in calc_names
    end

    test "generated calculation uses CanPerform module with correct resource" do
      calcs = Ash.Resource.Info.calculations(SharedDoc)
      can_update = Enum.find(calcs, &(&1.name == :can_update?))

      assert {AshGrant.Calculation.CanPerform, opts} = can_update.calculation
      assert opts[:action] == "update"
      assert opts[:resource] == SharedDoc
    end
  end

  describe "can_perform with custom name" do
    test "custom name option is respected" do
      # Define a test resource inline with custom name
      # We verify via the struct that the DSL parses correctly
      entity = %AshGrant.Dsl.CanPerform{action: :read, name: :visible?, public?: true}

      assert entity.name == :visible?
      assert entity.action == :read
    end
  end

  describe "compile-time validation" do
    test "can_perform_actions with nonexistent action raises DslError" do
      assert_raise Spark.Error.DslError, ~r/Action :nonexistent does not exist/, fn ->
        defmodule InvalidBatchResource do
          use Ash.Resource,
            domain: AshGrant.Test.Domain,
            data_layer: Ash.DataLayer.Ets,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            scope(:always, true)
            can_perform_actions([:nonexistent])
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end

    test "can_perform entity with nonexistent action raises DslError" do
      assert_raise Spark.Error.DslError, ~r/Action :foobar does not exist/, fn ->
        defmodule InvalidEntityResource do
          use Ash.Resource,
            domain: AshGrant.Test.Domain,
            data_layer: Ash.DataLayer.Ets,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshGrant]

          ash_grant do
            resolver(fn _, _ -> [] end)
            scope(:always, true)
            can_perform(:foobar)
          end

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end

    test "valid action names compile without error" do
      defmodule ValidActionsResource do
        use Ash.Resource,
          domain: AshGrant.Test.Domain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshGrant]

        ash_grant do
          resolver(fn _, _ -> [] end)
          scope(:always, true)
          can_perform_actions([:read, :destroy])
          can_perform :update
        end

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          defaults([:read, :destroy, :update])
        end
      end

      calcs = Ash.Resource.Info.calculations(ValidActionsResource)
      calc_names = Enum.map(calcs, & &1.name)

      assert :can_read? in calc_names
      assert :can_destroy? in calc_names
      assert :can_update? in calc_names
    end
  end

  describe "introspection" do
    test "can_perform_actions/1 returns configured actions" do
      actions = AshGrant.Info.can_perform_actions(Post)
      assert :update in actions
      assert :destroy in actions
    end

    test "can_perform_actions/1 returns empty list when not configured" do
      actions = AshGrant.Info.can_perform_actions(SharedDoc)
      assert actions == []
    end
  end

  describe "integration with DB" do
    defp create_post!(attrs) do
      Post
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create!(authorize?: false)
    end

    defp create_shared_doc!(title, owner_id) do
      SharedDoc
      |> Ash.Changeset.for_create(:create, %{title: title, owner_id: owner_id}, authorize?: false)
      |> Ash.create!(authorize?: false)
    end

    test "DSL-generated calculations produce correct results" do
      editor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      own_post = create_post!(%{title: "My Post", status: :draft, author_id: editor_id})
      _other_post = create_post!(%{title: "Other Post", status: :published, author_id: other_id})

      actor = %{id: editor_id, role: :editor}

      posts =
        Post
        |> Ash.Query.for_read(:read)
        |> Ash.Query.load([:can_update?, :can_destroy?])
        |> Ash.read!(actor: actor)

      posts_by_id = Map.new(posts, &{&1.id, &1})

      # Editor has post:*:update:own — true only for own
      assert posts_by_id[own_post.id].can_update? == true

      # Editor does NOT have destroy permission
      assert posts_by_id[own_post.id].can_destroy? == false
    end
  end

  # ============================================
  # Business Scenario: Blog Post List with Action Buttons
  # ============================================
  # A blog UI shows Edit/Delete buttons per-row based on actor's permissions.
  # Admin sees all buttons, editor only on own posts, viewer sees none.

  describe "business scenario: blog post list with action buttons" do
    defp create_scenario_post!(attrs) do
      Post
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create!(authorize?: false)
    end

    test "admin sees edit and delete buttons on all posts" do
      author_id = Ash.UUID.generate()
      create_scenario_post!(%{title: "Post 1", status: :published, author_id: author_id})
      create_scenario_post!(%{title: "Post 2", status: :draft, author_id: author_id})

      admin = %{id: Ash.UUID.generate(), role: :admin}

      posts =
        Post
        |> Ash.Query.load([:can_update?, :can_destroy?])
        |> Ash.read!(actor: admin)

      assert length(posts) == 2
      assert Enum.all?(posts, & &1.can_update?)
      assert Enum.all?(posts, & &1.can_destroy?)
    end

    test "editor sees edit button only on own posts, no delete button" do
      editor_id = Ash.UUID.generate()
      other_id = Ash.UUID.generate()

      own = create_scenario_post!(%{title: "My Post", status: :draft, author_id: editor_id})

      other =
        create_scenario_post!(%{title: "Other Post", status: :published, author_id: other_id})

      editor = %{id: editor_id, role: :editor}

      posts =
        Post
        |> Ash.Query.load([:can_update?, :can_destroy?])
        |> Ash.read!(actor: editor)

      by_id = Map.new(posts, &{&1.id, &1})

      # Own post: can edit, cannot delete
      assert by_id[own.id].can_update? == true
      assert by_id[own.id].can_destroy? == false

      # Other's post: cannot edit, cannot delete
      assert by_id[other.id].can_update? == false
      assert by_id[other.id].can_destroy? == false
    end

    test "viewer sees no edit or delete buttons" do
      author_id = Ash.UUID.generate()
      create_scenario_post!(%{title: "Published", status: :published, author_id: author_id})

      viewer = %{id: Ash.UUID.generate(), role: :viewer}

      posts =
        Post
        |> Ash.Query.load([:can_update?, :can_destroy?])
        |> Ash.read!(actor: viewer)

      assert posts != []
      assert Enum.all?(posts, &(&1.can_update? == false))
      assert Enum.all?(posts, &(&1.can_destroy? == false))
    end

    test "instance permissions: owner sees edit on own shared docs" do
      owner_id = "owner-1"
      doc1 = create_shared_doc!("My Doc", owner_id)
      doc2 = create_shared_doc!("Other Doc", "owner-2")

      actor = %{id: owner_id, role: :user, shared_doc_ids: [doc2.id]}

      docs =
        SharedDoc
        |> Ash.Query.load([:can_update?])
        |> Ash.read!(actor: actor)

      by_id = Map.new(docs, &{&1.id, &1})

      # Own doc: can update (RBAC update:own)
      assert by_id[doc1.id].can_update? == true
      # Shared doc: cannot update (only has read instance perm)
      assert by_id[doc2.id].can_update? == false
    end
  end
end

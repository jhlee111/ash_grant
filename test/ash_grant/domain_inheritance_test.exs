defmodule AshGrant.DomainInheritanceTest do
  use ExUnit.Case, async: true

  alias AshGrant.Info
  alias AshGrant.Test.DomainInheritedPost
  alias AshGrant.Test.DomainOverridePost
  alias AshGrant.Test.DomainMinimalPost
  alias AshGrant.Test.DomainCrossInheritPost
  alias AshGrant.Test.ResolverOnlyPost
  alias AshGrant.Test.ScopesOnlyPost

  # ── helpers ──────────────────────────────────────────────

  defp actor(id, perms), do: %{id: id, permissions: perms}

  defp create!(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  defp read_ids(resource, actor) do
    resource
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  # ── DSL introspection: resolver ──────────────────────────

  describe "resolver inheritance" do
    test "resource inherits resolver from domain" do
      resolver = Info.resolver(DomainInheritedPost)
      assert is_function(resolver, 2)

      a = %{permissions: ["domain_inherited_post:*:read:always"]}
      assert resolver.(a, %{}) == ["domain_inherited_post:*:read:always"]
    end

    test "resource resolver takes precedence over domain" do
      resolver = Info.resolver(DomainOverridePost)
      assert is_function(resolver, 2)

      assert resolver.(%{role: :admin}, %{}) == ["domain_override_post:*:*:always"]
    end

    test "existing resource in plain domain keeps own resolver" do
      resolver = Info.resolver(AshGrant.Test.Post)
      assert is_function(resolver, 2)
      assert resolver.(%{role: :admin}, %{}) == ["post:*:*:always"]
    end

    test "domain provides resolver only, resource adds scopes" do
      resolver = Info.resolver(ResolverOnlyPost)
      assert is_function(resolver, 2)

      a = %{permissions: ["resolver_only_post:*:read:always"]}
      assert resolver.(a, %{}) == ["resolver_only_post:*:read:always"]
    end

    test "resource provides resolver, domain provides scopes only" do
      resolver = Info.resolver(ScopesOnlyPost)
      assert is_function(resolver, 2)

      a = %{permissions: ["scopes_only_post:*:read:always"]}
      assert resolver.(a, %{}) == ["scopes_only_post:*:read:always"]
    end
  end

  # ── DSL introspection: scopes ────────────────────────────

  describe "scope inheritance" do
    test "resource inherits all scopes from domain" do
      names = scope_names(DomainInheritedPost)
      assert :always in names
      assert :own in names
    end

    test "resource scope overrides domain scope with same name" do
      filter_str =
        DomainOverridePost
        |> Info.resolve_scope_filter(:own, %{})
        |> inspect()

      # resource uses creator_id, domain uses author_id
      assert filter_str =~ "creator_id"
      refute filter_str =~ "author_id"
    end

    test "resource adds scopes beyond domain's" do
      names = scope_names(DomainMinimalPost)
      assert :always in names
      assert :own in names
      assert :published in names
    end

    test "domain and resource scopes are merged (no duplicates)" do
      assert scope_names(DomainMinimalPost) |> Enum.sort() == [:always, :own, :published]
    end

    test "domain :always scope inherits correctly as true" do
      assert Info.resolve_scope_filter(DomainInheritedPost, :always, %{}) == true
    end

    test "domain provides scopes only, resource inherits them" do
      names = scope_names(ScopesOnlyPost)
      assert :always in names
      assert :own in names
      assert :published in names
    end

    test "domain provides resolver only, resource defines own scopes" do
      names = scope_names(ResolverOnlyPost)
      assert :always in names
      assert :own in names
    end

    test "unknown scope returns false" do
      assert Info.resolve_scope_filter(DomainInheritedPost, :nonexistent, %{}) == false
    end
  end

  # ── cross-boundary scope inheritance ─────────────────────

  describe "cross-boundary scope inheritance" do
    test "resource scope inherits from domain-defined parent" do
      scope = Info.get_scope(DomainCrossInheritPost, :own_draft)
      assert scope.inherits == [:own]

      # :own must be present (merged from domain)
      assert Info.get_scope(DomainCrossInheritPost, :own) != nil
    end

    test "resolve_scope_filter combines parent and child" do
      filter_str =
        DomainCrossInheritPost
        |> Info.resolve_scope_filter(:own_draft, %{})
        |> inspect()

      # :own (author_id) AND :own_draft (status == :draft)
      assert filter_str =~ "author_id"
      assert filter_str =~ "status"
    end

    test "resolve_write_scope_filter works with domain-inherited parent" do
      filter_str =
        DomainCrossInheritPost
        |> Info.resolve_write_scope_filter(:own_draft, %{})
        |> inspect()

      assert filter_str =~ "author_id"
      assert filter_str =~ "status"
    end
  end

  # ── Domain.Info unit tests ───────────────────────────────

  describe "AshGrant.Domain.Info" do
    test "configured? returns true for domain with AshGrant.Domain" do
      assert AshGrant.Domain.Info.configured?(AshGrant.Test.GrantDomain)
    end

    test "configured? returns false for domain without AshGrant.Domain" do
      refute AshGrant.Domain.Info.configured?(AshGrant.Test.Domain)
    end

    test "resolver/1 returns domain resolver" do
      resolver = AshGrant.Domain.Info.resolver(AshGrant.Test.GrantDomain)
      assert is_function(resolver, 2)
    end

    test "resolver/1 returns nil when domain has no resolver" do
      assert AshGrant.Domain.Info.resolver(AshGrant.Test.ScopesOnlyDomain) == nil
    end

    test "scopes/1 returns domain scopes" do
      names =
        AshGrant.Test.GrantDomain
        |> AshGrant.Domain.Info.scopes()
        |> Enum.map(& &1.name)

      assert :always in names
      assert :own in names
    end

    test "scopes/1 returns empty for domain with no scopes" do
      assert AshGrant.Domain.Info.scopes(AshGrant.Test.ResolverOnlyDomain) == []
    end

    test "get_scope/2 finds a scope by name" do
      scope = AshGrant.Domain.Info.get_scope(AshGrant.Test.GrantDomain, :own)
      assert scope.name == :own
    end

    test "get_scope/2 returns nil for unknown scope" do
      assert AshGrant.Domain.Info.get_scope(AshGrant.Test.GrantDomain, :nope) == nil
    end
  end

  # ── validation ───────────────────────────────────────────

  describe "validation" do
    test "compile error when no resolver in resource or domain" do
      assert_raise Spark.Error.DslError, ~r/No resolver configured/, fn ->
        defmodule NoResolverResource do
          use Ash.Resource,
            domain: AshGrant.Test.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            scope(:always, true)
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
  end

  # ── end-to-end authorization ─────────────────────────────

  describe "e2e: read with domain-inherited config" do
    test "actor with :always scope reads all records" do
      id = Ash.UUID.generate()
      r1 = create!(DomainInheritedPost, %{title: "A", author_id: id})
      r2 = create!(DomainInheritedPost, %{title: "B", author_id: Ash.UUID.generate()})

      ids = read_ids(DomainInheritedPost, actor(id, ["domain_inherited_post:*:read:always"]))

      assert r1.id in ids
      assert r2.id in ids
    end

    test "actor with :own scope reads only own records" do
      me = Ash.UUID.generate()
      other = Ash.UUID.generate()
      mine = create!(DomainInheritedPost, %{title: "Mine", author_id: me})
      theirs = create!(DomainInheritedPost, %{title: "Theirs", author_id: other})

      ids = read_ids(DomainInheritedPost, actor(me, ["domain_inherited_post:*:read:own"]))

      assert mine.id in ids
      refute theirs.id in ids
    end

    test "actor with no permissions gets Forbidden" do
      create!(DomainInheritedPost, %{title: "X", author_id: Ash.UUID.generate()})

      assert_raise Ash.Error.Forbidden, fn ->
        Ash.read!(DomainInheritedPost, actor: actor(Ash.UUID.generate(), []))
      end
    end

    test "nil actor gets Forbidden" do
      create!(DomainInheritedPost, %{title: "X", author_id: Ash.UUID.generate()})

      assert_raise Ash.Error.Forbidden, fn ->
        Ash.read!(DomainInheritedPost, actor: nil)
      end
    end
  end

  describe "e2e: write with domain-inherited config" do
    test "actor with create permission can create" do
      me = Ash.UUID.generate()
      a = actor(me, ["domain_inherited_post:*:create:always"])

      result =
        DomainInheritedPost
        |> Ash.Changeset.for_create(:create, %{title: "New", author_id: me}, actor: a)
        |> Ash.create!()

      assert result.title == "New"
    end

    test "actor without create permission gets Forbidden" do
      me = Ash.UUID.generate()
      a = actor(me, ["domain_inherited_post:*:read:always"])

      assert_raise Ash.Error.Forbidden, fn ->
        DomainInheritedPost
        |> Ash.Changeset.for_create(:create, %{title: "Nope", author_id: me}, actor: a)
        |> Ash.create!()
      end
    end

    test "actor with :own update scope can update own record" do
      me = Ash.UUID.generate()
      rec = create!(DomainInheritedPost, %{title: "Old", author_id: me})
      a = actor(me, ["domain_inherited_post:*:update:own"])

      updated =
        rec
        |> Ash.Changeset.for_update(:update, %{title: "New"}, actor: a)
        |> Ash.update!()

      assert updated.title == "New"
    end

    test "actor with :own update scope cannot update others' record" do
      me = Ash.UUID.generate()
      other = Ash.UUID.generate()
      rec = create!(DomainInheritedPost, %{title: "Other", author_id: other})
      a = actor(me, ["domain_inherited_post:*:update:own"])

      assert_raise Ash.Error.Forbidden, fn ->
        rec
        |> Ash.Changeset.for_update(:update, %{title: "Hack"}, actor: a)
        |> Ash.update!()
      end
    end
  end

  describe "e2e: overridden scope" do
    test "override :own uses resource's field, not domain's" do
      me = Ash.UUID.generate()

      # creator_id = me (resource's :own field), author_id = someone else
      mine =
        create!(DomainOverridePost, %{
          title: "Mine",
          creator_id: me,
          author_id: Ash.UUID.generate()
        })

      # author_id = me but creator_id = someone else — should NOT match resource's :own
      not_mine =
        create!(DomainOverridePost, %{
          title: "Not mine",
          creator_id: Ash.UUID.generate(),
          author_id: me
        })

      ids = read_ids(DomainOverridePost, actor(me, ["domain_override_post:*:read:own"]))

      assert mine.id in ids
      refute not_mine.id in ids
    end
  end

  describe "e2e: merged scopes (domain + resource)" do
    test "actor reads via resource-only :published scope" do
      me = Ash.UUID.generate()
      pub = create!(DomainMinimalPost, %{title: "Pub", author_id: me, status: :published})
      draft = create!(DomainMinimalPost, %{title: "Draft", author_id: me, status: :draft})

      ids = read_ids(DomainMinimalPost, actor(me, ["domain_minimal_post:*:read:published"]))

      assert pub.id in ids
      refute draft.id in ids
    end

    test "actor reads via domain-inherited :own scope" do
      me = Ash.UUID.generate()
      other = Ash.UUID.generate()
      mine = create!(DomainMinimalPost, %{title: "Mine", author_id: me, status: :draft})
      theirs = create!(DomainMinimalPost, %{title: "Theirs", author_id: other, status: :draft})

      ids = read_ids(DomainMinimalPost, actor(me, ["domain_minimal_post:*:read:own"]))

      assert mine.id in ids
      refute theirs.id in ids
    end
  end

  describe "e2e: cross-boundary scope inheritance" do
    test "own_draft scope filters by author + draft status" do
      me = Ash.UUID.generate()
      other = Ash.UUID.generate()

      my_draft =
        create!(DomainCrossInheritPost, %{title: "My Draft", author_id: me, status: :draft})

      my_pub =
        create!(DomainCrossInheritPost, %{title: "My Pub", author_id: me, status: :published})

      other_draft =
        create!(DomainCrossInheritPost, %{title: "Other Draft", author_id: other, status: :draft})

      ids =
        read_ids(
          DomainCrossInheritPost,
          actor(me, ["domain_cross_inherit_post:*:read:own_draft"])
        )

      assert my_draft.id in ids
      refute my_pub.id in ids
      refute other_draft.id in ids
    end
  end

  describe "e2e: scopes-only domain (resource provides resolver)" do
    test "read works with resource resolver + domain scopes" do
      me = Ash.UUID.generate()
      pub = create!(ScopesOnlyPost, %{title: "Pub", author_id: me, status: :published})
      draft = create!(ScopesOnlyPost, %{title: "Draft", author_id: me, status: :draft})

      ids = read_ids(ScopesOnlyPost, actor(me, ["scopes_only_post:*:read:published"]))

      assert pub.id in ids
      refute draft.id in ids
    end
  end

  describe "e2e: resolver-only domain (resource provides scopes)" do
    test "read works with domain resolver + resource scopes" do
      me = Ash.UUID.generate()
      other = Ash.UUID.generate()
      mine = create!(ResolverOnlyPost, %{title: "Mine", author_id: me})
      theirs = create!(ResolverOnlyPost, %{title: "Theirs", author_id: other})

      ids = read_ids(ResolverOnlyPost, actor(me, ["resolver_only_post:*:read:own"]))

      assert mine.id in ids
      refute theirs.id in ids
    end
  end

  # ── deny-wins with domain inheritance ────────────────────

  describe "e2e: deny-wins with domain-inherited config" do
    test "deny rule overrides allow" do
      me = Ash.UUID.generate()
      create!(DomainInheritedPost, %{title: "X", author_id: me})

      a =
        actor(me, [
          "domain_inherited_post:*:read:always",
          "!domain_inherited_post:*:read:always"
        ])

      assert_raise Ash.Error.Forbidden, fn ->
        Ash.read!(DomainInheritedPost, actor: a)
      end
    end
  end

  # ── regression ───────────────────────────────────────────

  describe "regression" do
    test "existing resources in plain domain still work" do
      assert Info.resolver(AshGrant.Test.Post) != nil
      assert Info.scopes(AshGrant.Test.Post) != []
    end

    test "resource_name derivation works with domain inheritance" do
      assert Info.resource_name(DomainInheritedPost) == "domain_inherited_post"
    end

    test "default_policies setting preserved with domain inheritance" do
      assert Info.default_policies(DomainInheritedPost) == true
    end

    test "configured? returns true after domain merge" do
      assert Info.configured?(DomainInheritedPost)
    end

    test "multiple resources in same domain are independent" do
      # DomainOverridePost has own :own scope, DomainInheritedPost has domain's :own
      override_filter = Info.resolve_scope_filter(DomainOverridePost, :own, %{}) |> inspect()
      inherited_filter = Info.resolve_scope_filter(DomainInheritedPost, :own, %{}) |> inspect()

      assert override_filter =~ "creator_id"
      assert inherited_filter =~ "author_id"
      refute inherited_filter =~ "creator_id"
    end
  end

  # ── private ──────────────────────────────────────────────

  defp scope_names(resource) do
    resource |> Info.scopes() |> Enum.map(& &1.name)
  end
end

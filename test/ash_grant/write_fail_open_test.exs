defmodule AshGrant.WriteFailOpenContextPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.WriteFailOpenContextDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    resource_name("context_post")

    scope(:always, true)
    scope(:region, expr(region == ^context(:region)))

    default_policies(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:region, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.WriteFailOpenContextDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGrant.WriteFailOpenContextPost)
  end
end

defmodule AshGrant.WriteFailOpenOrgTenant do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: Ash.DataLayer.Ets

  multitenancy do
    strategy(:attribute)
    attribute(:organization_id)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:organization_id, :string, public?: true)
  end

  actions do
    defaults([:read])
  end
end

defmodule AshGrant.WriteFailOpenTest do
  @moduledoc """
  Regression tests for the write-path fail-open fixes (#136).

  Four paths in `AshGrant.Check` authorized a write when they should fail
  closed. Each fix is covered below:

  - #2: a filter referencing neither tenant nor actor fell through to
    `true` — now fails closed (fragment scope).
  - #3: `^context(:key)` was silently dropped on the write path — now
    resolved from the changeset/query context.
  - #4: the tenant check hardcoded `:tenant_id` and assumed OK when the field
    was absent — now uses the multitenancy attribute and fails closed.
  """
  use AshGrant.DataCase, async: true

  require Ash.Expr

  alias AshGrant.Test.Post
  alias AshGrant.WriteFailOpenContextPost
  alias AshGrant.WriteFailOpenOrgTenant

  # === #4: tenant attribute ===

  describe "check_tenant_match/3 uses the multitenancy attribute (#136 #4)" do
    test "matches the configured attribute, not a hardcoded :tenant_id" do
      record = %{organization_id: "org-a"}

      assert AshGrant.Check.check_tenant_match(record, "org-a", WriteFailOpenOrgTenant)
      refute AshGrant.Check.check_tenant_match(record, "org-b", WriteFailOpenOrgTenant)
    end

    test "fails closed when the record has no tenant value" do
      refute AshGrant.Check.check_tenant_match(%{}, "org-a", WriteFailOpenOrgTenant)
    end
  end

  # === #2: fallback default ===

  describe "fallback fails closed when neither tenant nor actor is referenced (#136 #2)" do
    test "a filter with no tenant/actor refs fails closed" do
      filter = Ash.Expr.expr(status == :published)
      context = %{resource: Post, tenant: nil, actor: nil}

      refute AshGrant.Check.fallback_evaluation(%{status: :published}, filter, context)
    end
  end

  # === #3: ^context on write ===

  describe "^context(:key) resolves on the write path (#136 #3)" do
    test "changeset context reaches a direct-attribute scope" do
      record =
        WriteFailOpenContextPost
        |> Ash.Changeset.for_create(:create, %{region: "us"}, authorize?: false)
        |> Ash.create!()

      actor = %{id: Ash.UUID.generate(), permissions: ["context_post:*:update:region"]}

      result =
        record
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.set_context(%{region: "us"})
        |> Ash.update(actor: actor)

      assert {:ok, _} = result
    end

    test "a non-matching context denies the write" do
      record =
        WriteFailOpenContextPost
        |> Ash.Changeset.for_create(:create, %{region: "us"}, authorize?: false)
        |> Ash.create!()

      actor = %{id: Ash.UUID.generate(), permissions: ["context_post:*:update:region"]}

      result =
        record
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.set_context(%{region: "eu"})
        |> Ash.update(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end
end

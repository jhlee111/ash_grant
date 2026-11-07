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

defmodule AshGrant.WriteFailOpenTest do
  @moduledoc """
  Regression tests for the write-path fail-open fixes (#136).

  Covers #3: `^context(:key)` was silently dropped on the write path. It is
  now resolved from the changeset/query context.

  #2 and #4 were fixes to `AshGrant.Check.fallback_evaluation/3`, which has
  since been removed. A scope `Ash.Expr.eval` cannot evaluate now denies the
  write (see `write_eval_error_fail_open_test.exs`).
  """
  use AshGrant.DataCase, async: true

  alias AshGrant.WriteFailOpenContextPost

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

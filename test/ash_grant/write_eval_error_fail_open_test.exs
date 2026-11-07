defmodule AshGrant.Test.EvalErrorItem do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrant.Test.EvalErrorDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrant]

  postgres do
    table("bulk_test_items")
    repo(AshGrant.TestRepo)
  end

  ash_grant do
    resolver(fn actor, _context ->
      case actor do
        %{permissions: perms} -> perms
        _ -> []
      end
    end)

    resource_name("eval_error_item")
    default_policies(true)

    scope(:always, true)
    scope(:own_numeric_title, expr(author_id == ^actor(:id) and type(title, :integer) == 1))
    scope(:own_or_numeric_title, expr(author_id == ^actor(:id) or type(title, :integer) == 1))

    scope(
      :own_not_numeric_title,
      expr(author_id == ^actor(:id) and not (type(title, :integer) == 1))
    )
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:author_id, :uuid, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshGrant.Test.EvalErrorDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshGrant.Test.EvalErrorItem)
  end
end

defmodule AshGrant.WriteEvalErrorFailOpenTest do
  @moduledoc """
  When `Ash.Expr.eval` cannot evaluate a write scope against the record, the
  write check must deny, not decide from the parts of the filter it recognises.
  """
  use AshGrant.DataCase, async: true

  import ExUnit.CaptureLog

  alias AshGrant.Test.EvalErrorItem

  defp actor_with(scope) do
    %{
      id: Ash.UUID.generate(),
      permissions: ["eval_error_item:*:update:#{scope}", "eval_error_item:*:read:always"]
    }
  end

  defp create_item!(attrs) do
    EvalErrorItem
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp update_item(item, actor) do
    item
    |> Ash.Changeset.for_update(:update, %{title: "Updated"})
    |> Ash.update(actor: actor)
  end

  describe "a scope whose cast fails on the record" do
    test "an `and` scope is forbidden to the author" do
      author = actor_with("own_numeric_title")
      item = create_item!(%{title: "not a number", author_id: author.id})

      capture_log(fn ->
        assert {:error, %Ash.Error.Forbidden{}} = update_item(item, author)
      end)
    end

    test "an `and not` scope is forbidden to the author" do
      author = actor_with("own_not_numeric_title")
      item = create_item!(%{title: "not a number", author_id: author.id})

      capture_log(fn ->
        assert {:error, %Ash.Error.Forbidden{}} = update_item(item, author)
      end)
    end

    test "logs a warning naming the resource" do
      author = actor_with("own_numeric_title")
      item = create_item!(%{title: "not a number", author_id: author.id})

      log = capture_log(fn -> update_item(item, author) end)

      assert log =~ "could not evaluate"
      assert log =~ inspect(EvalErrorItem)
    end
  end

  describe "a scope whose cast succeeds on the record" do
    test "an `and` scope is allowed for the author" do
      author = actor_with("own_numeric_title")
      item = create_item!(%{title: "1", author_id: author.id})

      assert {:ok, %{title: "Updated"}} = update_item(item, author)
    end

    test "an `or` scope is allowed for a non-author when the cast matches" do
      item = create_item!(%{title: "1", author_id: Ash.UUID.generate()})

      assert {:ok, %{title: "Updated"}} = update_item(item, actor_with("own_or_numeric_title"))
    end
  end
end

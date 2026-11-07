defmodule AshGrant.ResolverFallbackIntegrationTest.AppResolver do
  @moduledoc false
  @behaviour AshGrant.PermissionResolver

  @impl true
  def resolve(nil, _context), do: []
  def resolve(actor, _context), do: Map.get(actor, :permissions, [])
end

defmodule AshGrant.ResolverFallbackIntegrationTest do
  @moduledoc """
  Authorizes real requests on a resource whose only resolver is the app-wide
  `config :ash_grant, resolver:` fallback: a read through `FilterCheck`, a
  write through `Check`, and the compile-time `ValidateResolverPresent`
  warning that the fallback is meant to silence.

  The resources are compiled in `setup_all` with the app config set, the same
  order an application uses (config is loaded before its resources compile).

  Not async: the fallback is a global `Application` env the suite shares, and
  compile warnings are captured from `:stderr`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias __MODULE__.AppResolver

  @ns "AshGrant.ResolverFallbackIntegrationTest"
  @post Module.concat([@ns, "Post"])

  setup_all do
    stderr =
      with_app_resolver(AppResolver, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string(domain_source("Domain"))
          Code.compile_string(resource_source("Post", "Domain"))
        end)
      end)

    {:ok, compile_stderr: stderr}
  end

  setup do
    previous = Application.get_env(:ash_grant, :resolver)
    Application.put_env(:ash_grant, :resolver, AppResolver)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp with_app_resolver(value, fun) do
    previous = Application.get_env(:ash_grant, :resolver)

    case value do
      nil -> Application.delete_env(:ash_grant, :resolver)
      value -> Application.put_env(:ash_grant, :resolver, value)
    end

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp restore(nil), do: Application.delete_env(:ash_grant, :resolver)
  defp restore(value), do: Application.put_env(:ash_grant, :resolver, value)

  defp actor(id, perms), do: %{id: id, permissions: perms}

  defp seed do
    for {author, title} <- [{1, "mine"}, {2, "theirs"}] do
      Ash.create!(@post, %{author_id: author, title: title}, authorize?: false)
    end
  end

  defp titles(records), do: records |> Enum.map(& &1.title) |> Enum.sort()

  describe "a resource with only the app-config resolver" do
    test "compiles without the missing-resolver warning", %{compile_stderr: stderr} do
      refute stderr =~ "No resolver configured"
    end

    test "FilterCheck uses the app resolver's grants to filter a read" do
      seed()

      assert titles(Ash.read!(@post, actor: actor(1, ["post:*:read:own"]))) == ["mine"]

      assert titles(Ash.read!(@post, actor: actor(1, ["post:*:read:always"]))) == [
               "mine",
               "theirs"
             ]

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(@post, actor: actor(1, []))
    end

    test "Check uses the app resolver's grants to authorize a write" do
      [mine, theirs] = seed()
      me = actor(1, ["post:*:read:always", "post:*:update:own"])

      assert {:ok, %{title: "edited"}} =
               mine
               |> Ash.Changeset.for_update(:update, %{title: "edited"}, actor: me)
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               theirs
               |> Ash.Changeset.for_update(:update, %{title: "edited"}, actor: me)
               |> Ash.update()
    end
  end

  describe "ValidateResolverPresent" do
    test "warns when no resolver is configured anywhere, and not once the app config is set" do
      without =
        with_app_resolver(nil, fn ->
          capture_io(:stderr, fn ->
            Code.compile_string(domain_source("NoResolverDomain"))
            Code.compile_string(resource_source("NoResolverPost", "NoResolverDomain"))
          end)
        end)

      with_config =
        with_app_resolver(AppResolver, fn ->
          capture_io(:stderr, fn ->
            Code.compile_string(domain_source("AppResolverDomain"))
            Code.compile_string(resource_source("AppResolverPost", "AppResolverDomain"))
          end)
        end)

      assert without =~ "No resolver configured for #{@ns}.NoResolverPost"
      refute with_config =~ "No resolver configured"
    end
  end

  defp domain_source(name) do
    """
    defmodule #{@ns}.#{name} do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        allow_unregistered?(true)
      end
    end
    """
  end

  defp resource_source(name, domain) do
    """
    defmodule #{@ns}.#{name} do
      use Ash.Resource,
        domain: #{@ns}.#{domain},
        data_layer: Ash.DataLayer.Ets,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshGrant]

      ets do
        private?(true)
      end

      ash_grant do
        resource_name("post")
        default_policies(true)
        scope(:always, true)
        scope(:own, expr(author_id == ^actor(:id)))
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:author_id, :integer, public?: true)
        attribute(:title, :string, public?: true)
      end

      actions do
        defaults([:read, create: :*, update: :*])
      end
    end
    """
  end
end

defmodule AshGrant.ScopeRegistryIntegrationTest.Registry do
  @moduledoc false
  use AshGrant.ScopeRegistry

  scopes do
    scope(:always, true)
    scope(:own, expr(author_id == ^actor(:id)))
    scope(:by_owner_arg, expr(^arg(:owner_id) == ^actor(:id)))
  end
end

defmodule AshGrant.ScopeRegistryIntegrationTest do
  @moduledoc """
  Authorizes real requests through scopes that come from the app-wide
  `AshGrant.ScopeRegistry`, so the registry is exercised by `FilterCheck`,
  `Check`, scope inheritance and `resolve_argument`, not just by
  `AshGrant.Info.scopes/1`.

  The resources are compiled inside `setup_all`, after the registry is
  configured. That is also what an application does (config is loaded before
  its resources compile), and it is what `ValidateArgumentResolvers` needs to
  see a registry scope at compile time.

  Not async: the registry is read through `Application.get_env`, a global the
  suite shares, and compile warnings are captured from `:stderr`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias __MODULE__.Registry

  @ns "AshGrant.ScopeRegistryIntegrationTest"

  setup_all do
    previous = Application.get_env(:ash_grant, :scope_registry)
    Application.put_env(:ash_grant, :scope_registry, Registry)

    stderr =
      capture_io(:stderr, fn ->
        Code.compile_string(domain_source())
        Code.compile_string(resource_source("RegPost", ""))

        Code.compile_string(
          resource_source("RegInheritPost", "scope(:own_draft, [:own], expr(status == :draft))")
        )

        Code.compile_string(
          resource_source(
            "RegArgPost",
            "resolve_argument(:owner_id, from_path: [:author_id], for_actions: [:reassign])"
          )
        )
      end)

    on_exit(fn -> restore(previous) end)

    {:ok, compile_stderr: stderr}
  end

  setup do
    # Another async: false module may have changed or cleared the registry
    # between setup_all and this test; scopes are read at request time.
    previous = Application.get_env(:ash_grant, :scope_registry)
    Application.put_env(:ash_grant, :scope_registry, Registry)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:ash_grant, :scope_registry)
  defp restore(value), do: Application.put_env(:ash_grant, :scope_registry, value)

  defp mod(name), do: Module.concat([@ns, name])

  defp actor(id, perms), do: %{id: id, permissions: perms}

  defp seed(resource) do
    for {author, status} <- [{1, :draft}, {1, :published}, {2, :draft}] do
      Ash.create!(resource, %{author_id: author, status: status}, authorize?: false)
    end
  end

  defp rows(records), do: records |> Enum.map(&{&1.author_id, &1.status}) |> Enum.sort()

  describe "a resource whose only scopes come from the registry" do
    test "FilterCheck filters a read by the registry's :own scope" do
      resource = mod("RegPost")
      seed(resource)

      assert rows(Ash.read!(resource, actor: actor(1, ["regpost:*:read:own"]))) ==
               [{1, :draft}, {1, :published}]
    end

    test "Check authorizes a write by the registry's :own scope" do
      resource = mod("RegPost")
      [mine, _, theirs] = seed(resource)
      me = actor(1, ["regpost:*:read:always", "regpost:*:update:own"])

      assert {:ok, %{status: :archived}} =
               mine
               |> Ash.Changeset.for_update(:update, %{status: :archived}, actor: me)
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               theirs
               |> Ash.Changeset.for_update(:update, %{status: :archived}, actor: me)
               |> Ash.update()
    end
  end

  describe "a resource scope that inherits from a registry scope" do
    test "the filter is the AND of the registry parent and the local child" do
      resource = mod("RegInheritPost")
      seed(resource)

      assert rows(Ash.read!(resource, actor: actor(1, ["reginheritpost:*:read:own_draft"]))) ==
               [{1, :draft}]
    end
  end

  describe "resolve_argument referenced only by a registry scope" do
    test "compiles without the unreferenced-argument warning", %{compile_stderr: stderr} do
      refute stderr =~ "no scope references"
    end

    test "the argument is resolved, so the registry scope authorizes the write" do
      resource = mod("RegArgPost")
      [mine, _, theirs] = seed(resource)
      me = actor(1, ["regargpost:*:read:always", "regargpost:*:reassign:by_owner_arg"])

      assert {:ok, %{status: :archived}} =
               mine
               |> Ash.Changeset.for_update(:reassign, %{status: :archived}, actor: me)
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               theirs
               |> Ash.Changeset.for_update(:reassign, %{status: :archived}, actor: me)
               |> Ash.update()
    end
  end

  defp domain_source do
    """
    defmodule #{@ns}.Domain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        allow_unregistered?(true)
      end
    end
    """
  end

  defp resource_source(name, extra) do
    """
    defmodule #{@ns}.#{name} do
      use Ash.Resource,
        domain: #{@ns}.Domain,
        data_layer: Ash.DataLayer.Ets,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshGrant]

      ets do
        private?(true)
      end

      ash_grant do
        resolver(fn actor, _ -> (actor && actor[:permissions]) || [] end)
        resource_name("#{Macro.underscore(name) |> String.replace("_", "")}")
        default_policies(true)
        #{extra}
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:author_id, :integer, public?: true)
        attribute(:status, :atom, public?: true)
      end

      actions do
        defaults([:read, create: :*, update: :*])

        update :reassign do
          accept([:status])
          # `ResolveArgument` loads the path before the write, so it cannot run
          # atomically.
          require_atomic?(false)
        end
      end
    end
    """
  end
end

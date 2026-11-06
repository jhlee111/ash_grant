defmodule AshGrant.ResolverFallbackTest do
  # Not async: the fallback is looked up through `Application.get_env`, which
  # is a global the suite shares. Flipping it on/off inside a parallel run
  # would be seen by any other test that reads `AshGrant.Info.resolver/1`.
  use ExUnit.Case, async: false

  alias AshGrant.Info

  alias AshGrant.Test.ResolverFallbackDomainOverridePost
  alias AshGrant.Test.ResolverFallbackDomainResolver
  alias AshGrant.Test.ResolverFallbackOnlyPost
  alias AshGrant.Test.ResolverFallbackResolver
  alias AshGrant.Test.ResolverFallbackResourceOverridePost
  alias AshGrant.Test.ResolverFallbackResourceResolver

  # `ResolverFallbackOnlyPost` declares no resolver at either level, so it is
  # compiled here with the app config set rather than in `test/support`, where
  # it would need a suite-wide `config :ash_grant, resolver:`.
  setup_all do
    warnings =
      compile_with_app_resolver("""
      defmodule AshGrant.Test.ResolverFallbackOnlyDomain do
        use Ash.Domain,
          extensions: [AshGrant.Domain],
          validate_config_inclusion?: false

        resources do
          resource(AshGrant.Test.ResolverFallbackOnlyPost)
        end
      end

      defmodule AshGrant.Test.ResolverFallbackOnlyPost do
        use Ash.Resource,
          domain: AshGrant.Test.ResolverFallbackOnlyDomain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrant]

        ash_grant do
          scope(:always, true)
        end

        actions do
          defaults([:read])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:author_id, :uuid, public?: true)
        end
      end
      """)

    assert warnings == ""
    :ok
  end

  setup do
    previous = Application.get_env(:ash_grant, :resolver)
    Application.put_env(:ash_grant, :resolver, ResolverFallbackResolver)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ash_grant, :resolver)
        other -> Application.put_env(:ash_grant, :resolver, other)
      end
    end)

    :ok
  end

  describe "Info.resolver/1 precedence" do
    test "resource with no resolver and domain with no resolver picks up app config" do
      assert Info.resolver(ResolverFallbackOnlyPost) == ResolverFallbackResolver
    end

    test "returns nil when no resolver is configured at any level" do
      Application.delete_env(:ash_grant, :resolver)
      assert Info.resolver(ResolverFallbackOnlyPost) == nil
    end

    test "domain resolver wins over app config" do
      assert Info.resolver(ResolverFallbackDomainOverridePost) ==
               ResolverFallbackDomainResolver
    end

    test "resource resolver wins over app config" do
      assert Info.resolver(ResolverFallbackResourceOverridePost) ==
               ResolverFallbackResourceResolver
    end

    test "resource resolver wins over domain resolver (unchanged)" do
      # Sanity check: the pre-existing resource > domain precedence still
      # holds with the app-config fallback in place.
      assert Info.resolver(ResolverFallbackResourceOverridePost) ==
               ResolverFallbackResourceResolver
    end
  end

  describe "AshGrant.check runtime" do
    test "authorizes successfully when only the app-config resolver is set" do
      {:ok, _result} =
        ResolverFallbackOnlyPost
        |> Ash.Query.for_read(:read)
        |> Ash.read(actor: %{id: Ecto.UUID.generate()})
    end
  end

  describe "ValidateScopes with only the app-config resolver" do
    test "still reports deprecated options and a missing instance_key" do
      suffix = System.unique_integer([:positive])
      domain_name = Module.concat(__MODULE__, "ScopeChecksDomain#{suffix}")
      module_name = Module.concat(__MODULE__, "ScopeChecksPost#{suffix}")

      warnings =
        compile_with_app_resolver("""
        defmodule #{inspect(domain_name)} do
          use Ash.Domain, validate_config_inclusion?: false

          resources do
            resource(#{inspect(module_name)})
          end
        end

        defmodule #{inspect(module_name)} do
          use Ash.Resource,
            domain: #{inspect(domain_name)},
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshGrant]

          ash_grant do
            owner_field(:author_id)
            instance_key(:no_such_attribute)
            scope(:always, true)
          end

          actions do
            defaults([:read])
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:author_id, :uuid, public?: true)
          end
        end
        """)

      assert warnings =~ "owner_field is deprecated"
      assert warnings =~ "instance_key :no_such_attribute does not exist"
    end
  end

  defp compile_with_app_resolver(source) do
    previous = Application.get_env(:ash_grant, :resolver)
    Application.put_env(:ash_grant, :resolver, ResolverFallbackResolver)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source) end)
    after
      case previous do
        nil -> Application.delete_env(:ash_grant, :resolver)
        other -> Application.put_env(:ash_grant, :resolver, other)
      end
    end
  end
end

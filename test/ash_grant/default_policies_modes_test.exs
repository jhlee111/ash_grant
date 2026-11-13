defmodule AshGrant.DefaultPoliciesModesTest do
  @moduledoc """
  Pins what each `default_policies` value generates.

  `default_policies` takes `false`, `true`, `:all`, `:read` or `:write`
  (`AshGrant.Transformers.AddDefaultPolicies`). Only `true` was exercised
  elsewhere; these tests cover every value, both as the generated policy list
  and as the authorization outcome:

  - `true` / `:all` — read, create/update/destroy, and generic actions
  - `:read` — read only; writes and generic actions are left to the resource's own policies
  - `:write` — create/update/destroy only; reads and generic actions are left to the resource's own policies
  - `false` — nothing
  """
  use ExUnit.Case, async: true

  alias __MODULE__.{AllMode, FalseMode, ReadMode, TrueMode, WriteMode}

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  # One resource per mode. Each has every action type, so a test can tell which
  # ones the generated policies cover.
  for {name, mode} <- [
        TrueMode: true,
        AllMode: :all,
        ReadMode: :read,
        WriteMode: :write,
        FalseMode: false
      ] do
    Module.create(
      Module.concat(__MODULE__, name),
      quote do
        @moduledoc false
        use Ash.Resource,
          domain: AshGrant.DefaultPoliciesModesTest.Domain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshGrant]

        ets do
          private?(true)
        end

        ash_grant do
          resolver(fn
            %{permissions: perms}, _ -> perms
            _, _ -> []
          end)

          default_policies(unquote(mode))
          scope(:always, true)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: [:title], update: [:title]])

          action :ping, :string do
            run(fn _input, _context -> {:ok, "pong"} end)
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )
  end

  @everything %{permissions: ["*:*:*:always"]}

  # The action types each generated policy is conditioned on, with its check.
  defp generated(resource) do
    resource
    |> Ash.Policy.Info.policies()
    |> Enum.map(fn %{condition: [{Ash.Policy.Check.ActionType, opts}], policies: [check]} ->
      {opts[:type], check.check_module}
    end)
  end

  defp seed!(resource) do
    resource
    |> Ash.Changeset.for_create(:create, %{title: "seed"}, authorize?: false)
    |> Ash.create!()
  end

  defp read(resource, actor), do: Ash.read(resource, actor: actor)

  defp create(resource, actor) do
    resource
    |> Ash.Changeset.for_create(:create, %{title: "new"}, actor: actor)
    |> Ash.create()
  end

  defp update(record, actor) do
    record
    |> Ash.Changeset.for_update(:update, %{title: "changed"}, actor: actor)
    |> Ash.update()
  end

  defp ping(resource, actor) do
    resource
    |> Ash.ActionInput.for_action(:ping, %{}, actor: actor)
    |> Ash.run_action()
  end

  describe "generated policies" do
    @read_write_generic [
      {[:read], AshGrant.FilterCheck},
      {[:create, :update, :destroy], AshGrant.Check},
      {[:action], AshGrant.Check}
    ]

    test "true generates read, write and generic action policies" do
      assert generated(TrueMode) == @read_write_generic
    end

    test ":all generates the same policies as true" do
      assert generated(AllMode) == @read_write_generic
    end

    test ":read generates only the read policy" do
      assert generated(ReadMode) == [{[:read], AshGrant.FilterCheck}]
    end

    test ":write generates only the create/update/destroy policy" do
      assert generated(WriteMode) == [{[:create, :update, :destroy], AshGrant.Check}]
    end

    test "false generates nothing" do
      assert generated(FalseMode) == []
    end
  end

  describe "authorization with a grant for everything" do
    test "true and :all authorize reads, writes and generic actions" do
      for resource <- [TrueMode, AllMode] do
        record = seed!(resource)

        assert {:ok, [_ | _]} = read(resource, @everything)
        assert {:ok, _} = create(resource, @everything)
        assert {:ok, _} = update(record, @everything)
        assert {:ok, "pong"} = ping(resource, @everything)
      end
    end

    test ":read authorizes reads; writes and generic actions have no policy and are forbidden" do
      record = seed!(ReadMode)

      assert {:ok, [_ | _]} = read(ReadMode, @everything)
      assert {:error, %Ash.Error.Forbidden{}} = create(ReadMode, @everything)
      assert {:error, %Ash.Error.Forbidden{}} = update(record, @everything)
      assert {:error, %Ash.Error.Forbidden{}} = ping(ReadMode, @everything)
    end

    test ":write authorizes writes; reads and generic actions have no policy and are forbidden" do
      record = seed!(WriteMode)

      assert {:error, %Ash.Error.Forbidden{}} = read(WriteMode, @everything)
      assert {:ok, _} = create(WriteMode, @everything)
      assert {:ok, _} = update(record, @everything)
      assert {:error, %Ash.Error.Forbidden{}} = ping(WriteMode, @everything)
    end

    test "false has no policy for anything, so everything is forbidden" do
      record = seed!(FalseMode)

      assert {:error, %Ash.Error.Forbidden{}} = read(FalseMode, @everything)
      assert {:error, %Ash.Error.Forbidden{}} = create(FalseMode, @everything)
      assert {:error, %Ash.Error.Forbidden{}} = update(record, @everything)
      assert {:error, %Ash.Error.Forbidden{}} = ping(FalseMode, @everything)
    end
  end

  describe "the generated policies still check grants" do
    test ":read forbids a read with no grant" do
      seed!(ReadMode)

      assert {:error, %Ash.Error.Forbidden{}} = read(ReadMode, %{permissions: []})
    end

    test ":write forbids a write with no grant" do
      assert {:error, %Ash.Error.Forbidden{}} = create(WriteMode, %{permissions: []})
    end
  end
end

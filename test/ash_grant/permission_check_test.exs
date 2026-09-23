defmodule AshGrant.PermissionCheckTest do
  @moduledoc """
  `AshGrant.PermissionValidation.check/2` and `check_all/2` (issue #162): the
  static checker that compares a stored permission string against the
  application's resources.

  The last describe block pins the checker to the runtime: the real checks are
  run with each generated string, and must raise the undeclared-scope error on
  exactly the resources the checker names.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrant.PermissionValidation

  # Grants arrive through the actor, so each test controls what a check sees.
  defmodule Resolver do
    @moduledoc false
    def resolve(actor, _context), do: Map.get(actor || %{}, :permissions, [])
  end

  defmodule Note do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ash_grant do
      resolver(AshGrant.PermissionCheckTest.Resolver)
      resource_name("note")

      scope(:always, [], true)
      scope(:own, [], expr(owner_id == ^actor(:id)))

      field_group(:public, [:title])
      field_group(:sensitive, [:body], inherits: [:public])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:body, :string, public?: true)
      attribute(:owner_id, :uuid, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])

      update :publish do
        accept([])
      end
    end
  end

  # Shares `own` with Note, has `own_unit` and `approve` to itself, and declares
  # no field groups.
  defmodule Memo do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ash_grant do
      resolver(AshGrant.PermissionCheckTest.Resolver)
      resource_name("memo")

      scope(:own, [], expr(owner_id == ^actor(:id)))
      scope(:own_unit, [], expr(unit_id == ^actor(:unit_id)))
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:owner_id, :uuid, public?: true)
      attribute(:unit_id, :uuid, public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])

      update :approve do
        accept([])
      end
    end
  end

  # Field groups, but not Note's `sensitive`.
  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(AshGrant.PermissionCheckTest.Resolver)
      resource_name("ledger")

      scope(:always, [], true)
      field_group(:public, [:amount])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:amount, :integer, public?: true)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Legacy do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(AshGrant.PermissionCheckTest.Resolver)
      resource_name("legacy")
      scope_resolver(fn _scope, _context -> true end)
      scope(:always, [], true)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  # Policies that match permissions under names the resource itself never
  # declares: a virtual action and a second resource name.
  defmodule Overridden do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshGrant]

    ash_grant do
      resolver(AshGrant.PermissionCheckTest.Resolver)
      resource_name("overridden")
      scope(:always, [], true)
    end

    policies do
      policy action_type(:read) do
        authorize_if(AshGrant.filter_check(resource: "content"))
      end

      policy action_type(:update) do
        authorize_if(AshGrant.check(action: "moderate"))
      end
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, update: :*])
    end
  end

  # Reply reaches Thread's instance permissions through `scope_through`, under
  # its own action names.
  defmodule Thread do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(AshGrant.PermissionCheckTest.Resolver)
      resource_name("thread")
      scope(:always, [], true)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Reply do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(AshGrant.PermissionCheckTest.Resolver)
      resource_name("reply")
      scope(:always, [], true)
      scope_through(:thread)
    end

    attributes do
      uuid_primary_key(:id)
    end

    relationships do
      belongs_to(:thread, AshGrant.PermissionCheckTest.Thread)
    end

    actions do
      defaults([:read, update: :*])

      update :moderate do
        accept([])
      end
    end
  end

  # No resolver: not a configured AshGrant resource, so the checker ignores it.
  defmodule Plain do
    @moduledoc false
    use Ash.Resource, domain: nil, validate_domain_inclusion?: false

    attributes do
      uuid_primary_key(:id)
    end
  end

  @resources [Note, Memo, Ledger]

  defp issues_for(permission, resources \\ @resources),
    do: PermissionValidation.check(permission, resources: resources)

  defp codes(permission, resources \\ @resources),
    do: permission |> issues_for(resources) |> Enum.map(& &1.code)

  describe "valid strings return no issues" do
    for permission <- [
          "note:*:read:always",
          "note:*:read:always:sensitive",
          "!note:*:destroy:always",
          "note:9f1c:read:",
          "note:9f1c:*:",
          "!note:9f1c:destroy:",
          "*:*:update:own",
          "*:*:*:all",
          "note:*:@read:always",
          "note:*:@update:own",
          "note:*:publish:own",
          "note:*:*:own",
          # legacy 3-part and 2-part forms
          "note:read:own",
          "note:read"
        ] do
      test permission do
        assert issues_for(unquote(permission)) == []
      end
    end

    test "every representation a resolver may return is accepted" do
      struct = AshGrant.Permission.parse!("note:*:read:own")
      input = %AshGrant.PermissionInput{string: "note:*:read:own", description: "own notes"}

      assert issues_for(struct) == []
      assert issues_for(input) == []
    end
  end

  describe "each wrong segment returns exactly its code" do
    test "a string that does not parse" do
      assert [%{code: :parse_error, severity: :error, segment: :permission} = issue] =
               issues_for("note:*:read:always:public:extra")

      assert issue.permission == "note:*:read:always:public:extra"
    end

    test "something that is not a permission at all" do
      assert [%{code: :parse_error}] = issues_for(42)
    end

    test "resource" do
      assert [%{code: :unknown_resource, severity: :error, segment: :resource} = issue] =
               issues_for("nots:*:read:always")

      assert issue.message =~ "Did you mean `note`?"
    end

    test "action" do
      assert [%{code: :unknown_action, severity: :error, segment: :action} = issue] =
               issues_for("note:*:reed:always")

      assert issue.resources == [Note]
      assert issue.message =~ "Did you mean `read`?"
    end

    test "action on an instance permission" do
      assert codes("note:9f1c:reed:") == [:unknown_action]
    end

    test "scope" do
      assert [%{code: :undeclared_scope, severity: :error, segment: :scope} = issue] =
               issues_for("note:*:read:owm")

      assert issue.resources == [Note]
      assert issue.message =~ "Did you mean `own`?"
    end

    test "field group" do
      assert [%{code: :unknown_field_group, severity: :error, segment: :field_group} = issue] =
               issues_for("note:*:read:always:sensitiv")

      assert issue.resources == [Note]
      assert issue.message =~ "Did you mean `sensitive`?"
    end

    test "a field group on a resource that declares none" do
      assert codes("memo:*:read:own:public") == [:unknown_field_group]
    end

    test "a grant that matches no action is reported for its action alone" do
      # Nothing reads the scope of a grant that applies nowhere, so it cannot
      # raise. It is checked once the action is fixed.
      assert codes("note:*:reed:owm") == [:unknown_action]
    end
  end

  describe "builtin scopes" do
    test "always, all, and global need no declaration" do
      # Memo declares none of them.
      assert issues_for("memo:*:read:always") == []
      assert issues_for("memo:*:update:all") == []
      assert issues_for("memo:*:read:global") == []
      assert issues_for("memo:*:update:global") == []
    end

    test "global is universal on the read and write paths (#139)" do
      assert issues_for("memo:*:read:global") == []
      assert issues_for("memo:*:@read:global") == []
      assert issues_for("memo:*:update:global") == []
      assert issues_for("memo:*:*:global") == []
    end

    test "global grants on the write path without a declaration (#139)" do
      actor = %{
        id: Ash.UUID.generate(),
        unit_id: Ash.UUID.generate(),
        permissions: ["memo:*:update:global"]
      }

      update = Ash.Resource.Info.action(Memo, :update)

      assert run_check(Memo, update, actor) == true
    end
  end

  describe "scope_resolver" do
    test "turns an unknown scope into a warning" do
      assert [%{code: :unverifiable_scope, severity: :warning, resources: [Legacy]}] =
               issues_for("legacy:*:read:anything", [Legacy])
    end

    test "declared and builtin scopes are still silent" do
      assert issues_for("legacy:*:read:always", [Legacy]) == []
      assert issues_for("legacy:*:read:all", [Legacy]) == []
    end

    test "only covers the resources that configure one" do
      issues = issues_for("*:*:read:own_unit", [Memo, Note, Legacy])

      assert [
               %{code: :scope_missing_on, severity: :error, resources: [Note]},
               %{code: :unverifiable_scope, severity: :warning, resources: [Legacy]}
             ] = issues
    end
  end

  describe "a `*` resource" do
    test "reports the one resource that lacks the scope, by name" do
      assert [%{code: :scope_missing_on, severity: :error} = issue] = issues_for("*:*:read:own")

      assert issue.resources == [Ledger]
      assert issue.message =~ inspect(Ledger)
    end

    test "a scope no resource declares is undeclared, not missing-on" do
      assert [%{code: :undeclared_scope} = issue] = issues_for("*:*:read:nowhere")
      assert Enum.sort(issue.resources) == Enum.sort(@resources)
    end

    test "only the resources the grant can apply to need the scope" do
      # `approve` exists on Memo alone, and Memo declares `own_unit`. Note and
      # Ledger never see this grant, so they owe it nothing.
      assert issues_for("*:*:approve:own_unit") == []
    end

    test "an action no resource has" do
      assert [%{code: :unknown_action, resources: resources}] = issues_for("*:*:aprove:own")
      assert Enum.sort(resources) == Enum.sort(@resources)
    end

    test "reports the resources that lack the field group" do
      assert [%{code: :field_group_missing_on, resources: [Ledger]}] =
               issues_for("*:*:read:always:sensitive")
    end

    test "a resource with no field groups is not expected to declare one" do
      # Memo has none; Note and Ledger both declare `public`.
      assert issues_for("*:*:read:all:public") == []
    end

    test "a field group nobody declares" do
      assert codes("*:*:read:all:nowhere") == [:unknown_field_group]
    end
  end

  describe "deny and instance permissions" do
    test "an undeclared scope is a warning: the framework never reads it" do
      assert [%{code: :undeclared_scope, severity: :warning} = deny] =
               issues_for("!note:*:read:owm")

      assert deny.message =~ "deny applies whatever its scope"

      assert [%{code: :undeclared_scope, severity: :warning} = instance] =
               issues_for("note:9f1c:read:business_hours")

      assert instance.message =~ "get_instance_scope"
    end

    test "deny + field_group is the #117 rule, as a code" do
      assert [%{code: :deny_with_field_group, severity: :error, segment: :field_group}] =
               issues_for("!note:*:read:always:sensitive")
    end

    test "deny + field_group does not also report the group as unknown" do
      assert codes("!note:*:read:always:nowhere") == [:deny_with_field_group]
    end
  end

  describe "type wildcards reuse diagnostics/1" do
    test "the deprecated spelling is a warning" do
      assert [%{code: :deprecated_type_wildcard, severity: :warning, segment: :action}] =
               issues_for("note:*:read*:always")
    end

    test "a type Ash does not have is an error" do
      assert [%{code: :unknown_action_type, severity: :error}] =
               issues_for("note:*:@delete:always")
    end

    test "a type wildcard on an instance permission is a warning (#131)" do
      assert [%{code: :dead_instance_type_wildcard, severity: :warning}] =
               issues_for("note:9f1c:@read:")
    end

    test "a valid type with no action of that type on the resource is not an error" do
      # Ledger only has a read action; the grant is inert there, not misspelt.
      assert issues_for("ledger:*:@destroy:always") == []
    end
  end

  describe "names declared by a policy override" do
    test "an `action:` override is a known action" do
      assert issues_for("overridden:*:moderate:always", [Overridden]) == []
      assert codes("overridden:*:moderat:always", [Overridden]) == [:unknown_action]
    end

    test "a `resource:` override is a known resource" do
      assert issues_for("content:*:read:always", [Overridden]) == []
      assert issues_for("overridden:*:read:always", [Overridden]) == []
    end
  end

  describe "scope_through" do
    test "a parent instance permission may name a child's action" do
      # Check and FilterCheck match Thread's instance permissions against Reply's
      # action, so this grant is live even though Thread has no `moderate`.
      assert issues_for("thread:9f1c:moderate:", [Thread, Reply]) == []
    end

    test "but only an instance permission: RBAC grants do not propagate" do
      assert codes("thread:*:moderate:always", [Thread, Reply]) == [:unknown_action]
    end

    test "and only when the child is among the resources" do
      assert codes("thread:9f1c:moderate:", [Thread]) == [:unknown_action]
    end
  end

  describe "which resources are checked against" do
    test "no resources at all is reported as such, not as a misspelt name" do
      for permission <- ["note:*:read:always", "*:*:read:always"] do
        assert [%{code: :unknown_resource, message: message}] = issues_for(permission, [Plain])
        assert message =~ "No AshGrant resources to check against"
      end
    end

    test "a resource without a resolver is ignored" do
      assert codes("plain:*:read:always", [Plain, Note]) == [:unknown_resource]
    end

    test "otp_app: reads the application's ash_domains" do
      assert PermissionValidation.check("post:*:read:always", otp_app: :ash_grant) == []

      assert [%{code: :unknown_resource}] =
               PermissionValidation.check("note:*:read:always", otp_app: :ash_grant)
    end

    test "with no option, every AshGrant resource in the started applications is used" do
      assert PermissionValidation.check("post:*:read:always") == []
    end
  end

  describe "check_all/2" do
    test "returns one result per input, in order, duplicates included" do
      permissions = ["note:*:read:always", "note:*:read:owm", "note:*:read:always"]

      assert [
               {"note:*:read:always", []},
               {"note:*:read:owm", [%{code: :undeclared_scope}]},
               {"note:*:read:always", []}
             ] = PermissionValidation.check_all(permissions, resources: @resources)
    end

    test "errors?/1 tells errors from warnings" do
      [{_, warnings}, {_, errors}] =
        PermissionValidation.check_all(["note:*:read*:always", "note:*:read:owm"],
          resources: @resources
        )

      refute PermissionValidation.errors?(warnings)
      assert PermissionValidation.errors?(errors)
    end
  end

  # -- the static check and the runtime agree -----------------------------------

  @property_resources [Note, Memo, Ledger, Legacy]

  @undeclared_scope_error "not found in inline scope DSL"

  defp permission_string do
    gen all(
          deny <- member_of(["", "", "", "!"]),
          resource <- member_of(~w(note memo ledger legacy * nope)),
          instance <- member_of(["*", "*", "*", "9f1c"]),
          action <-
            member_of(~w(read create update destroy publish approve * @read @update @create
              @destroy @action read* bogus)),
          scope <- member_of(["always", "all", "global", "own", "own_unit", "nowhere", ""]),
          field_group <- member_of([nil, nil, "public", "sensitive", "nowhere"])
        ) do
      base = "#{deny}#{resource}:#{instance}:#{action}:#{scope}"
      if field_group, do: "#{base}:#{field_group}", else: base
    end
  end

  # Runs the check the default policies would run for `action`, with an actor
  # holding exactly `permission`, and reports whether it raised the
  # undeclared-scope error. The return value of the check is not the subject.
  defp raises_undeclared_scope?(resource, action, permission) do
    actor = %{id: Ash.UUID.generate(), unit_id: Ash.UUID.generate(), permissions: [permission]}

    try do
      run_check(resource, action, actor)
      false
    rescue
      error in RuntimeError ->
        if Exception.message(error) =~ @undeclared_scope_error,
          do: true,
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp run_check(resource, %{type: :read} = action, actor) do
    authorizer = %{resource: resource, action: action, query: Ash.Query.new(resource)}
    AshGrant.FilterCheck.filter(actor, authorizer, [])
  end

  defp run_check(resource, action, actor) do
    changeset = %{Ash.Changeset.new(resource) | action: action, action_type: action.type}
    authorizer = %{resource: resource, action: action, changeset: changeset}
    AshGrant.Check.match?(actor, authorizer, [])
  end

  defp resources_that_raise(permission) do
    for resource <- @property_resources,
        action <- Ash.Resource.Info.actions(resource),
        raises_undeclared_scope?(resource, action, permission),
        uniq: true,
        do: resource
  end

  defp resources_with_scope_error(issues) do
    for %{code: code, severity: :error, resources: resources} <- issues,
        code in [:undeclared_scope, :scope_missing_on],
        resource <- resources,
        uniq: true,
        do: resource
  end

  describe "the static check and the runtime agree" do
    # Generated strings include deny + field_group, which `validate/3` logs.
    @describetag capture_log: true

    test "the harness sees the raise it is looking for" do
      update = Ash.Resource.Info.action(Memo, :update)
      read = Ash.Resource.Info.action(Memo, :read)

      refute raises_undeclared_scope?(Memo, update, "memo:*:update:global")
      assert raises_undeclared_scope?(Memo, read, "memo:*:read:nowhere")
      refute raises_undeclared_scope?(Memo, read, "memo:*:read:global")
      refute raises_undeclared_scope?(Memo, update, "memo:*:update:own")
    end

    property "a string the checker accepts never raises the undeclared-scope error" do
      check all(permission <- permission_string(), max_runs: 500) do
        issues = issues_for(permission, @property_resources)

        unless PermissionValidation.errors?(issues) do
          assert resources_that_raise(permission) == []
        end
      end
    end

    property "the runtime raises on exactly the resources a scope error names" do
      check all(permission <- permission_string(), max_runs: 500) do
        named = permission |> issues_for(@property_resources) |> resources_with_scope_error()

        assert Enum.sort(resources_that_raise(permission)) == Enum.sort(named)
      end
    end
  end
end

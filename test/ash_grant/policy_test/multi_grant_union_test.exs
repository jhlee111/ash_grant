defmodule AshGrant.PolicyTest.MultiGrantUnionTest do
  @moduledoc """
  The PolicyTest framework must OR-compose multiple grants' scopes (#123),
  matching the runtime behavior of `AshGrant.Check`.

  Mirrors the incident that surfaced the bug: a director holds a blanket
  grant (`schedule:*:*:always`) plus a narrow add-on bundle
  (`schedule:*:cancel:online_content`). The narrow grant must not shadow
  the blanket one — regardless of permission order.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyTest.Assertions

  defmodule Schedule do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      extensions: [AshGrant]

    ash_grant do
      resolver(fn actor, _context -> (actor && Map.get(actor, :permissions)) || [] end)
      resource_name("schedule")

      scope(:always, true)
      scope(:online_content, expr(type == :online_education))
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:type, :atom, public?: true)
    end

    actions do
      defaults([:read])

      update :cancel do
        accept([])
      end
    end
  end

  defmodule SchedulePolicyTest do
    @moduledoc false
    use AshGrant.PolicyTest

    resource(AshGrant.PolicyTest.MultiGrantUnionTest.Schedule)

    actor(:director, %{
      permissions: ["schedule:*:cancel:online_content", "schedule:*:*:always"]
    })

    actor(:director_reversed, %{
      permissions: ["schedule:*:*:always", "schedule:*:cancel:online_content"]
    })

    actor(:content_manager, %{
      permissions: ["schedule:*:cancel:online_content"]
    })
  end

  describe "multiple grants OR-compose (#123)" do
    test "blanket grant authorizes records outside the narrow scope (narrow listed first)" do
      Assertions.do_assert_can(SchedulePolicyTest, :director, :cancel, %{type: :regular_class})
    end

    test "permission order does not matter" do
      Assertions.do_assert_can(
        SchedulePolicyTest,
        :director_reversed,
        :cancel,
        %{type: :regular_class}
      )
    end

    test "the narrow grant alone still denies records outside its scope" do
      Assertions.do_assert_cannot(
        SchedulePolicyTest,
        :content_manager,
        :cancel,
        %{type: :regular_class}
      )
    end

    test "the narrow grant alone allows records inside its scope" do
      Assertions.do_assert_can(
        SchedulePolicyTest,
        :content_manager,
        :cancel,
        %{type: :online_education}
      )
    end
  end
end

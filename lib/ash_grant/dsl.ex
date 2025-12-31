defmodule AshGrant.Dsl do
  @moduledoc """
  DSL definition for AshGrant extension.

  This module defines the `ash_grant` DSL section that can be added to
  Ash resources to configure permission-based authorization.

  ## DSL Options

  | Option | Type | Required | Description |
  |--------|------|----------|-------------|
  | `resolver` | module or function | **Yes** | Resolves permissions for actors |
  | `resource_name` | string | No | Resource name for permission matching |
  | `owner_field` | atom | No | Field for "own" scope resolution |

  ## Scope Entity

  The `scope` entity defines named scopes that translate to Ash filter expressions.
  This replaces the need for a separate `ScopeResolver` module.

  | Argument | Type | Description |
  |----------|------|-------------|
  | `name` | atom | The scope name (e.g., `:all`, `:own`, `:published`) |
  | `filter` | expression or boolean | The filter expression or `true` for no filter |

  | Option | Type | Description |
  |--------|------|-------------|
  | `inherits` | list of atoms | Parent scopes to inherit and combine with |

  ## Example

      defmodule MyApp.Blog.Post do
        use Ash.Resource,
          extensions: [AshGrant]

        ash_grant do
          resolver MyApp.PermissionResolver
          resource_name "post"
          owner_field :author_id

          scope :all, true
          scope :own, expr(author_id == ^actor(:id))
          scope :published, expr(status == :published)
          scope :own_draft, [:own], expr(status == :draft)
        end
      end

  ## Resolver

  The `resolver` option specifies how to get permissions for an actor.
  It can be:

  - A module implementing `AshGrant.PermissionResolver` behaviour
  - A 2-arity function `(actor, context) -> [permissions]`

  ## Resource Name

  The `resource_name` option overrides the resource name used in
  permission matching. If not specified, it's derived from the module
  name (e.g., `MyApp.Blog.Post` → `"post"`).

  ## Owner Field

  The `owner_field` option specifies which field identifies the owner
  of a record. This is used by scope resolvers to implement "own" scope.
  Common values: `:user_id`, `:author_id`, `:owner_id`, `:created_by_id`.
  """

  @scope %Spark.Dsl.Entity{
    name: :scope,
    describe: """
    Defines a named scope with its filter expression.

    Scopes are referenced in permissions as the fourth part: `resource:*:action:scope`

    ## Examples

        # No filtering - access to all records
        scope :all, true

        # Filter to records owned by the actor
        scope :own, expr(author_id == ^actor(:id))

        # Filter to published records
        scope :published, expr(status == :published)

        # Inheritance: combines parent scope(s) with this filter
        scope :own_draft, [:own], expr(status == :draft)
    """,
    examples: [
      "scope :all, true",
      "scope :own, expr(author_id == ^actor(:id))",
      "scope :published, expr(status == :published)",
      "scope :own_draft, [:own], expr(status == :draft)"
    ],
    target: AshGrant.Dsl.Scope,
    args: [:name, {:optional, :inherits}, :filter],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the scope"
      ],
      inherits: [
        type: {:list, :atom},
        doc: "List of parent scopes to inherit from"
      ],
      filter: [
        type: {:or, [:boolean, :any]},
        required: true,
        doc: "The filter expression or `true` for no filtering"
      ]
    ]
  }

  @ash_grant %Spark.Dsl.Section{
    name: :ash_grant,
    top_level?: false,
    imports: [Ash.Expr],
    describe: """
    Configuration for permission-based authorization.

    Note: The `expr` macro is automatically available within the `ash_grant` block.
    You can use it directly without needing to require or import `Ash.Expr`.
    """,
    examples: [
      """
      ash_grant do
        resolver MyApp.PermissionResolver
        resource_name "blog"
        owner_field :author_id

        scope :all, true
        scope :own, expr(author_id == ^actor(:id))
        scope :published, expr(status == :published)
      end
      """
    ],
    entities: [@scope],
    schema: [
      resolver: [
        type: {:or, [{:behaviour, AshGrant.PermissionResolver}, {:fun, 2}]},
        required: true,
        doc: """
        Module implementing `AshGrant.PermissionResolver` behaviour,
        or a 2-arity function `(actor, context) -> permissions`.

        This resolves permissions for the current actor.
        """
      ],
      scope_resolver: [
        type: {:or, [{:behaviour, AshGrant.ScopeResolver}, {:fun, 2}]},
        doc: """
        DEPRECATED: Use inline `scope` entities instead.

        Module implementing `AshGrant.ScopeResolver` behaviour,
        or a 2-arity function `(scope, context) -> filter`.

        This resolves scope strings to Ash filter expressions.
        If not provided, scopes are resolved from inline `scope` entities.
        """
      ],
      resource_name: [
        type: :string,
        doc: """
        The resource name used in permission matching.

        Defaults to the last part of the module name, lowercased.
        For example, `MyApp.Blog.Post` becomes `"post"`.
        """
      ],
      owner_field: [
        type: :atom,
        doc: """
        The field that identifies the owner of a record.

        Used for resolving the "own" scope. Common values are
        `:user_id`, `:author_id`, `:owner_id`, `:created_by_id`.
        """
      ],
      default_policies: [
        type: {:or, [:boolean, {:in, [:read, :write, :all]}]},
        default: false,
        doc: """
        Automatically generate standard AshGrant policies.

        When enabled, AshGrant will automatically add policies to your resource,
        eliminating the need to manually define the `policies` block.

        Options:
        - `false` - No policies are generated (default, explicit policies required)
        - `true` or `:all` - Generate policies for both read and write actions
        - `:read` - Only generate policy for read actions (filter_check)
        - `:write` - Only generate policy for write actions (check)

        Generated policies:
        ```elixir
        policies do
          policy action_type(:read) do
            authorize_if AshGrant.filter_check()
          end

          policy action_type([:create, :update, :destroy]) do
            authorize_if AshGrant.check()
          end
        end
        ```

        Note: When using `default_policies`, you should still add
        `authorizers: [Ash.Policy.Authorizer]` to your resource options.
        """
      ]
    ]
  }

  @sections [@ash_grant]

  def sections, do: @sections
end

defmodule AshGrant.Dsl.Scope do
  @moduledoc """
  Represents a scope definition in the AshGrant DSL.

  Scopes are named filter expressions that can be referenced
  in permissions to limit access to specific records.
  """

  defstruct [:name, :inherits, :filter, :__spark_metadata__]

  @type t :: %__MODULE__{
          name: atom(),
          inherits: [atom()] | nil,
          filter: boolean() | Ash.Expr.t(),
          __spark_metadata__: map() | nil
        }
end

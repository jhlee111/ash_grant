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
  | `default_policies` | boolean or atom | No | Auto-generate policies (`true`, `:all`, `:read`, `:write`) |
  | `default_field_policies` | boolean | No | Auto-generate `field_policies` from `field_group` definitions |
  | `owner_field` | atom | No | **Deprecated.** Use `scope :own, expr(...)` instead |

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
  | `write` | expression, boolean, or nil | Write-specific expression. Falls back to `filter` if omitted. |
  | `description` | string | Human-readable description for explain/4 output |

  ### Dual Read/Write Scope

  The `filter` expression is used for read actions (converted to SQL via `FilterCheck`).
  For write actions, `Check` evaluates the scope — simple scopes use in-memory
  evaluation, while scopes with relationship references (`exists()` or dot-paths)
  automatically use a DB query to verify the scope.

  The `write:` option is an optional override for explicit control:

      # Explicitly deny writes
      scope :readonly, expr(exists(org.users, id == ^actor(:id))),
        write: false

      # Explicit in-memory expression (avoids DB round-trip)
      scope :same_org, expr(exists(org.users, id == ^actor(:id))),
        write: expr(org_id == ^actor(:org_id))

  When `write:` is omitted, scopes with relationship references use a DB query
  fallback; simple scopes use in-memory evaluation.

  ## Example

      defmodule MyApp.Blog.Post do
        use Ash.Resource,
          extensions: [AshGrant]

        ash_grant do
          resolver MyApp.PermissionResolver
          resource_name "post"

          scope :all, true
          scope :own, expr(author_id == ^actor(:id))
          scope :published, expr(status == :published)
          scope :own_draft, [:own], expr(status == :draft)

          # Relational scope — works for reads and writes automatically
          scope :team_visible, expr(exists(team.members, user_id == ^actor(:id)))
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

  ## Owner Field (Deprecated)

  The `owner_field` option is **deprecated** and will be removed in v1.0.0.
  Use explicit scope expressions instead:

      # Instead of owner_field :author_id, use:
      scope :own, expr(author_id == ^actor(:id))

  ## Context Injection

  Scopes can use `^context(:key)` for injectable values, enabling deterministic
  testing of temporal and parameterized scopes:

      ash_grant do
        resolver MyApp.PermissionResolver

        # Injectable temporal scope
        scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))

        # Injectable threshold scope
        scope :small_amount, expr(amount < ^context(:max_amount))
      end

  Inject values at query/changeset time:

      Post
      |> Ash.Query.for_read(:read)
      |> Ash.Query.set_context(%{reference_date: Date.utc_today()})
      |> Ash.read!(actor: actor)

  This is preferred over database functions like `CURRENT_DATE` for testability.
  """

  @scope %Spark.Dsl.Entity{
    name: :scope,
    describe: """
    Defines a named scope with its filter expression.

    Scopes are referenced in permissions as the fourth part: `resource:*:action:scope`

    ## Examples

        # No filtering - access to all records
        scope :all, true, description: "All records without restriction"

        # Filter to records owned by the actor
        scope :own, expr(author_id == ^actor(:id)),
          description: "Records owned by the current user"

        # Filter to published records
        scope :published, expr(status == :published),
          description: "Published records visible to everyone"

        # Inheritance: combines parent scope(s) with this filter
        scope :own_draft, [:own], expr(status == :draft),
          description: "User's own records that are in draft status"

        # Context injection for testable temporal scopes
        scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date))),
          description: "Records created today"

        # Relational scope — DB query fallback handles writes automatically
        scope :team_member, expr(exists(team.members, user_id == ^actor(:id)))

        # Explicitly deny writes with this scope
        scope :readonly, expr(exists(org.users, id == ^actor(:id))),
          write: false

        # Description is optional - backward compatible
        scope :archived, expr(status == :archived)
    """,
    examples: [
      "scope :all, true",
      "scope :own, expr(author_id == ^actor(:id))",
      "scope :published, expr(status == :published)",
      "scope :own_draft, [:own], expr(status == :draft)",
      ~s|scope :today, expr(fragment("DATE(inserted_at) = ?", ^context(:reference_date)))|,
      ~s|scope :own, expr(author_id == ^actor(:id)), description: "Records owned by the current user"|,
      "scope :team_member, expr(exists(team.members, user_id == ^actor(:id)))",
      "scope :readonly, expr(exists(org.users, id == ^actor(:id))), write: false"
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
      ],
      description: [
        type: :string,
        required: false,
        doc: "Human-readable description of what this scope represents. Used in explain/4 output."
      ],
      write: [
        type: {:or, [:boolean, :any]},
        required: false,
        doc: """
        Optional override for write action evaluation. When omitted, scopes with
        relationship references use a DB query fallback; simple scopes use in-memory
        evaluation.

        Set to `false` to explicitly deny writes, or to an expression for explicit
        in-memory evaluation (avoids DB round-trip).

        ## Example

            scope :readonly, expr(exists(org.users, id == ^actor(:id))),
              write: false

            scope :same_org, expr(exists(org.users, id == ^actor(:id))),
              write: expr(org_id == ^actor(:org_id))
        """
      ]
    ]
  }

  @field_group %Spark.Dsl.Entity{
    name: :field_group,
    describe: """
    Defines a named field group for column-level read authorization.

    Field groups control which fields are visible to actors based on their permissions.
    The 5th part of the permission string references a field group name:
    `resource:instance:action:scope:field_group`

    ## Examples

        # Root group — no inheritance
        field_group :public, [:name, :department, :position]

        # All fields
        field_group :admin, :all

        # All fields except (blacklist)
        field_group :internal, :all, except: [:ssn, :tax_code]

        # Inherits from :public, adds more fields
        field_group :sensitive, [:phone, :address], inherits: [:public]

        # With masking
        field_group :sensitive, [:phone, :address], inherits: [:public] do
          mask [:phone, :address], with: &MyApp.Masker.mask/2
        end

        # Inherits + all except
        field_group :editor, :all, except: [:admin_notes], inherits: [:public]
    """,
    examples: [
      "field_group :public, [:name, :department]",
      "field_group :sensitive, [:phone, :address], inherits: [:public]",
      "field_group :admin, :all",
      "field_group :public, :all, except: [:salary, :ssn]"
    ],
    target: AshGrant.Dsl.FieldGroup,
    args: [:name, :fields],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the field group"
      ],
      inherits: [
        type: {:list, :atom},
        doc: "List of parent field groups to inherit from"
      ],
      fields: [
        type: {:or, [{:in, [:all]}, {:list, :atom}]},
        required: true,
        doc: "List of field atoms accessible at this level, or `:all` for all resource attributes"
      ],
      mask: [
        type: {:list, :atom},
        doc: "List of fields to mask at this level"
      ],
      mask_with: [
        type: {:fun, 2},
        doc: "2-arity masking function: (value, field_name) -> masked_value"
      ],
      except: [
        type: {:list, :atom},
        doc:
          "Fields to exclude when `fields` is `:all`. " <>
            "Only valid when `fields` is `:all`. " <>
            "The transformer resolves `:all` minus `except` to concrete field names."
      ],
      description: [
        type: :string,
        required: false,
        doc: "Human-readable description of this field group"
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

        scope :all, true
        scope :own, expr(author_id == ^actor(:id))
        scope :published, expr(status == :published)
      end
      """
    ],
    entities: [@scope, @field_group],
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
        DEPRECATED: Use explicit `scope :own, expr(field == ^actor(:id))` instead.

        The field that identifies the owner of a record. This option is
        deprecated and will be removed in v1.0.0.
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
      ],
      default_field_policies: [
        type: :boolean,
        default: false,
        doc: """
        Automatically generate Ash `field_policies` from `field_group` definitions.

        When `true`, AshGrant generates field policies that use `AshGrant.FieldCheck`
        to authorize field access based on the 5th part of permission strings.

        When `false` (default), you can manually write `field_policies` using
        `AshGrant.field_check/1` (Mode A).
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

  ## Fields

  - `:name` - The atom name of the scope (e.g., `:own`, `:published`)
  - `:inherits` - List of parent scope names to inherit from
  - `:filter` - The filter expression (`true` for no filtering, or an Ash.Expr)
  - `:write` - Optional write-specific expression. Falls back to `:filter` if nil. Set to `false` to deny writes.
  - `:description` - Optional human-readable description for debugging/explain
  """

  defstruct [:name, :inherits, :filter, :write, :description, :__spark_metadata__]

  @type t :: %__MODULE__{
          name: atom(),
          inherits: [atom()] | nil,
          filter: boolean() | Ash.Expr.t(),
          write: boolean() | Ash.Expr.t() | nil,
          description: String.t() | nil,
          __spark_metadata__: map() | nil
        }
end

defmodule AshGrant.Dsl.FieldGroup do
  @moduledoc """
  Represents a field group definition in the AshGrant DSL.

  Field groups define named sets of fields for column-level read authorization.
  They allow fine-grained control over which fields an actor can see, with
  support for inheritance, masking, and hierarchical field visibility.

  ## Fields

  - `:name` - The atom name of the field group (e.g., `:public`, `:sensitive`)
  - `:fields` - `:all` or list of field atoms included in this group (resolved to `[atom()]` by transformer)
  - `:inherits` - Optional list of parent field group names to inherit fields from
  - `:except` - Optional list of fields to exclude when `fields` is `:all`
  - `:mask` - Optional list of fields to mask (return masked values instead of hiding)
  - `:mask_with` - Optional 2-arity function `(value, field_name) -> masked_value`
  - `:description` - Optional human-readable description
  """

  defstruct [
    :name,
    :fields,
    :inherits,
    :except,
    :mask,
    :mask_with,
    :description,
    :__spark_metadata__
  ]

  @type t :: %__MODULE__{
          name: atom(),
          fields: :all | [atom()],
          inherits: [atom()] | nil,
          except: [atom()] | nil,
          mask: [atom()] | nil,
          mask_with: (any(), atom() -> any()) | nil,
          description: String.t() | nil,
          __spark_metadata__: map() | nil
        }
end

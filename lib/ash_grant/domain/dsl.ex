defmodule AshGrant.Domain.Dsl do
  @moduledoc """
  DSL definition for the AshGrant domain-level extension.

  This module defines the `ash_grant` DSL section that can be added to
  Ash domains to configure shared permission settings inherited by resources.

  Only `resolver` and `scope` entities are supported at the domain level.
  Resource-specific options like `resource_name`, `default_policies`, and
  `field_group` must be configured on each resource.

  ## Example

      defmodule MyApp.Blog do
        use Ash.Domain,
          extensions: [AshGrant.Domain]

        ash_grant do
          resolver MyApp.PermissionResolver

          scope :always, true
          scope :own, expr(author_id == ^actor(:id))
        end

        resources do
          resource MyApp.Blog.Post   # inherits resolver + scopes
          resource MyApp.Blog.Comment # inherits resolver + scopes
        end
      end
  """

  @ash_grant %Spark.Dsl.Section{
    name: :ash_grant,
    top_level?: false,
    imports: [Ash.Expr],
    describe: """
    Shared AshGrant configuration inherited by resources in this domain.

    Resources using the `AshGrant` extension will inherit the `resolver` and
    `scope` definitions from their domain, unless they define their own.
    """,
    examples: [
      """
      ash_grant do
        resolver MyApp.PermissionResolver

        scope :always, true
        scope :own, expr(author_id == ^actor(:id))
      end
      """
    ],
    entities: [AshGrant.Dsl.scope_entity()],
    schema: [
      resolver: [
        type: {:or, [{:behaviour, AshGrant.PermissionResolver}, {:fun, 2}]},
        required: false,
        doc: """
        Module implementing `AshGrant.PermissionResolver` behaviour,
        or a 2-arity function `(actor, context) -> permissions`.

        This resolver is inherited by all resources in the domain that
        use the `AshGrant` extension and don't define their own resolver.
        """
      ]
    ]
  }

  @sections [@ash_grant]

  def sections, do: @sections
end

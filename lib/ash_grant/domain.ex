defmodule AshGrant.Domain do
  @moduledoc """
  Domain-level extension for AshGrant.

  Add this extension to an Ash domain to define shared `resolver` and `scope`
  configurations that are automatically inherited by all resources in the domain
  that use the `AshGrant` extension.

  Resources can override any inherited setting by defining their own.

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
          resource MyApp.Blog.Post
          resource MyApp.Blog.Comment
        end
      end

  ## Inheritance Rules

  | Config | Resource has it | Domain has it | Result |
  |--------|----------------|---------------|--------|
  | resolver | Yes | Yes | Resource wins |
  | resolver | No | Yes | Domain's resolver used |
  | scope (same name) | Yes | Yes | Resource wins (override) |
  | scope | No | Yes | Domain scope inherited |
  """

  use Spark.Dsl.Extension,
    sections: AshGrant.Domain.Dsl.sections(),
    transformers: []
end

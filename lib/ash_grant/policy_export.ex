defmodule AshGrant.PolicyExport do
  @moduledoc """
  Exports policy configuration to various documentation formats.

  Supports:
  - **Mermaid** - Visual flowchart diagrams
  - **Markdown** - Human-readable documentation
  - **YAML** - `mix ash_grant.export --format=yaml`. To export a *policy test* module
    as YAML instead, see `AshGrant.PolicyTest.to_yaml/1`

  ## Examples

      # Generate Mermaid diagram
      mermaid = AshGrant.PolicyExport.to_mermaid(MyApp.Document)

      # Generate Markdown documentation
      markdown = AshGrant.PolicyExport.to_markdown(MyApp.Document)

      # Save to file
      File.write!("docs/document_policy.md", markdown)
  """

  alias AshGrant.PolicyExport.{Mermaid, Markdown}

  @doc """
  Generates a Mermaid flowchart diagram for a resource's policy.

  The diagram shows:
  - Resource name as the root
  - Actions as branches
  - Scopes as leaves

  ## Examples

      mermaid = AshGrant.PolicyExport.to_mermaid(MyApp.Document)
      # Returns a string like:
      # flowchart TD
      #   Document[Document]
      #   Document --> read
      #   read --> all
      #   read --> approved
      #   ...
  """
  @spec to_mermaid(module()) :: String.t()
  def to_mermaid(resource) do
    Mermaid.generate(resource)
  end

  @doc """
  Generates Markdown documentation for a resource's policy.

  The documentation includes:
  - Resource overview
  - Actions table
  - Scopes table with descriptions
  - Available permissions

  ## Examples

      markdown = AshGrant.PolicyExport.to_markdown(MyApp.Document)
  """
  @spec to_markdown(module()) :: String.t()
  def to_markdown(resource) do
    Markdown.generate(resource)
  end
end

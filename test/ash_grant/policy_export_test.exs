defmodule AshGrant.PolicyExportTest do
  @moduledoc """
  Tests for policy export functionality.
  """
  use ExUnit.Case, async: true

  alias AshGrant.PolicyExport
  alias AshGrant.PolicyExport.{Mermaid, Markdown}

  describe "PolicyExport.to_mermaid/1" do
    test "generates mermaid flowchart for resource" do
      mermaid = PolicyExport.to_mermaid(AshGrant.Test.Document)

      assert is_binary(mermaid)
      assert String.contains?(mermaid, "flowchart")
      assert String.contains?(mermaid, "Document")
    end

    test "includes actions" do
      mermaid = PolicyExport.to_mermaid(AshGrant.Test.Document)

      assert String.contains?(mermaid, "read")
      assert String.contains?(mermaid, "create")
      assert String.contains?(mermaid, "update")
    end

    test "includes scopes" do
      mermaid = PolicyExport.to_mermaid(AshGrant.Test.Document)

      assert String.contains?(mermaid, "always")
      assert String.contains?(mermaid, "draft")
      assert String.contains?(mermaid, "approved")
    end
  end

  describe "PolicyExport.to_markdown/1" do
    test "generates markdown documentation" do
      markdown = PolicyExport.to_markdown(AshGrant.Test.Document)

      assert is_binary(markdown)
      assert String.contains?(markdown, "# Document")
    end

    test "includes actions section" do
      markdown = PolicyExport.to_markdown(AshGrant.Test.Document)

      assert String.contains?(markdown, "## Actions")
      assert String.contains?(markdown, "read")
      assert String.contains?(markdown, "create")
    end

    test "includes scopes section" do
      markdown = PolicyExport.to_markdown(AshGrant.Test.Document)

      assert String.contains?(markdown, "## Scopes")
      assert String.contains?(markdown, "always")
      assert String.contains?(markdown, "draft")
    end

    test "includes permissions table" do
      markdown = PolicyExport.to_markdown(AshGrant.Test.Document)

      assert String.contains?(markdown, "## Permissions")
      assert String.contains?(markdown, "|")
    end
  end

  describe "Mermaid.generate/1" do
    test "generates valid mermaid syntax" do
      mermaid = Mermaid.generate(AshGrant.Test.Post)

      # Should start with flowchart directive
      assert String.starts_with?(mermaid, "flowchart")
    end
  end

  describe "Markdown.generate/1" do
    test "generates valid markdown" do
      markdown = Markdown.generate(AshGrant.Test.Post)

      # Should start with heading
      assert String.starts_with?(markdown, "#")
    end

    test "includes available permissions" do
      markdown = Markdown.generate(AshGrant.Test.Post)

      assert String.contains?(markdown, "post:*:")
    end
  end
end

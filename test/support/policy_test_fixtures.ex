defmodule AshGrant.PolicyTest.Fixtures.TestWithResource do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)
end

defmodule AshGrant.PolicyTest.Fixtures.TestWithActors do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:admin, %{role: :admin})
  actor(:reader, %{role: :reader})
  actor(:author, %{role: :author, id: "author_001"})
end

defmodule AshGrant.PolicyTest.Fixtures.TestWithDescribeAndTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:reader, %{role: :reader})

  describe "read access" do
    test "reader can read" do
      :ok
    end

    test "another test" do
      :ok
    end
  end

  describe "write access" do
    test "reader cannot write" do
      :ok
    end
  end
end

defmodule AshGrant.PolicyTest.Fixtures.TestWithoutDescribe do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:admin, %{role: :admin})

  test "admin can do anything" do
    :ok
  end
end

defmodule AshGrant.PolicyTest.Fixtures.TestWithFunctions do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:admin, %{role: :admin})

  test "returns value" do
    42
  end
end

defmodule AshGrant.PolicyTest.Fixtures.TestContextInheritance do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:reader, %{role: :reader})

  test "context is available" do
    :ok
  end
end

# Fixtures for testing assertions with actual resources

defmodule AshGrant.PolicyTest.Fixtures.DocumentPolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  # Define actors that match the Document resource's resolver
  actor(:admin, %{role: :admin})
  actor(:author, %{role: :author})
  actor(:reviewer, %{role: :reviewer})
  actor(:reader, %{role: :reader})
  actor(:guest, %{permissions: []})

  # Tests for assert_can without record
  test "admin can do anything" do
    assert_can(:admin, :read)
    assert_can(:admin, :create)
    assert_can(:admin, :update)
    assert_can(:admin, :destroy)
  end

  test "reader can read" do
    assert_can(:reader, :read)
  end

  test "guest cannot read" do
    assert_cannot(:guest, :read)
  end

  # Tests for assert_can with record
  test "reader can read approved documents" do
    assert_can(:reader, :read, %{status: :approved})
  end

  test "reader cannot read drafts" do
    assert_cannot(:reader, :read, %{status: :draft})
  end

  # Tests for action type keyword
  test "author can update" do
    assert_can(:author, action_type: :update)
  end

  # Test specific action - author has "document:*:update:*" which includes the "update" action
  test "author can update action" do
    assert_can(:author, action: :update)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.PostPolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Post)

  actor(:admin, %{role: :admin})
  actor(:editor, %{role: :editor, id: "editor_001"})
  actor(:viewer, %{role: :viewer})

  test "editor can read all posts" do
    assert_can(:editor, :read)
  end

  test "editor can update own posts" do
    assert_can(:editor, :update, %{author_id: "editor_001"})
  end

  test "editor cannot update others posts" do
    assert_cannot(:editor, :update, %{author_id: "other_user"})
  end

  test "viewer can read published posts" do
    assert_can(:viewer, :read, %{status: :published})
  end

  test "viewer cannot read drafts" do
    assert_cannot(:viewer, :read, %{status: :draft})
  end
end

# Edge case test fixtures

defmodule AshGrant.PolicyTest.Fixtures.NilActorTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:nobody, nil)

  test "nil actor cannot read" do
    assert_cannot(:nobody, :read)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.UndefinedActorTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:reader, %{role: :reader})

  test "undefined actor fails" do
    assert_can(:nonexistent, :read)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.SpecialCharsTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:reader, %{role: :reader})

  test "reader: can read (approved only)" do
    assert_can(:reader, :read)
  end

  test "test with 'quotes' and \"double quotes\"" do
    assert_can(:reader, :read)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.MultiAssertTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:admin, %{role: :admin})

  test "admin has full access" do
    assert_can(:admin, :read)
    assert_can(:admin, :create)
    assert_can(:admin, :update)
    assert_can(:admin, :destroy)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.FailFastTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:reader, %{role: :reader})

  test "first failure stops" do
    # This should fail
    assert_can(:reader, :create)
    # This won't be reached
    assert_can(:reader, :read)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.MissingFieldTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Document)

  actor(:reader, %{role: :reader})

  test "record without status field" do
    # Reader has permission document:*:read:approved
    # Record has no status - scope check might pass or fail
    # depending on implementation
    assert_can(:reader, :read, %{title: "test"})
  end
end

# Field visibility assertion tests

defmodule AshGrant.PolicyTest.Fixtures.FieldVisibilityTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.ExceptRecord)

  # Actor with :public field_group (:always except [:salary, :ssn])
  actor(:public_viewer, %{permissions: ["exceptrecord:*:read:always:public"]})
  # Actor with :full field_group (inherits :public, adds [:salary, :ssn])
  actor(:full_viewer, %{permissions: ["exceptrecord:*:read:always:full"]})
  # Actor with 4-part permission (no field_group restriction)
  actor(:unrestricted, %{permissions: ["exceptrecord:*:read:always"]})
  # Actor with no permissions
  actor(:nobody, %{permissions: []})

  test "public viewer sees non-sensitive fields" do
    assert_fields_visible(:public_viewer, :read, [:name, :email, :department])
  end

  test "public viewer cannot see salary and ssn" do
    assert_fields_hidden(:public_viewer, :read, [:salary, :ssn])
  end

  test "full viewer sees all fields" do
    assert_fields_visible(:full_viewer, :read, [:name, :salary, :ssn])
  end

  test "unrestricted sees all fields (4-part permission)" do
    assert_fields_visible(:unrestricted, :read, [:name, :salary, :ssn])
  end

  test "nobody has no visible fields" do
    assert_fields_hidden(:nobody, :read, [:name, :salary])
  end
end

# Field group except (blacklist) tests

defmodule AshGrant.PolicyTest.Fixtures.ExceptFieldGroupTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.ExceptRecord)

  # Actor with :public field_group (:always except [:salary, :ssn])
  actor(:public_viewer, %{permissions: ["exceptrecord:*:read:always:public"]})
  # Actor with :full field_group (inherits :public, adds [:salary, :ssn])
  actor(:full_viewer, %{permissions: ["exceptrecord:*:read:always:full"]})
  # Actor with 4-part permission (no field_group restriction)
  actor(:unrestricted, %{permissions: ["exceptrecord:*:read:always"]})
  # Actor with no permissions
  actor(:nobody, %{permissions: []})

  test "public viewer can read with except field group" do
    assert_can(:public_viewer, :read)
  end

  test "full viewer can read with full field group" do
    assert_can(:full_viewer, :read)
  end

  test "unrestricted viewer can read without field group" do
    assert_can(:unrestricted, :read)
  end

  test "nobody cannot read" do
    assert_cannot(:nobody, :read)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.FeedPolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.Feed)

  actor(:feed_reader, %{permissions: ["feed:feed_abc:read:"]})
  actor(:all_reader, %{permissions: ["feed:*:read:always"]})
  actor(:guest, %{permissions: []})

  test "feed_reader can read (instance permission)" do
    assert_can(:feed_reader, :read)
  end

  test "all_reader can read (RBAC)" do
    assert_can(:all_reader, :read)
  end

  test "guest cannot read" do
    assert_cannot(:guest, :read)
  end
end

defmodule AshGrant.PolicyTest.Fixtures.ScopeThroughTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.ChildComment)

  actor(:post_reader, %{permissions: ["post:post_123:read:"]})
  actor(:own_reader, %{id: "user_1", permissions: ["child_comment:*:read:own"]})
  actor(:nobody, %{permissions: []})

  test "post_reader can read (parent instance permission)" do
    assert_can(:post_reader, :read)
  end

  test "own_reader can read (RBAC scope)" do
    assert_can(:own_reader, :read)
  end

  test "nobody cannot read" do
    assert_cannot(:nobody, :read)
  end
end

# Generic action policy tests

defmodule AshGrant.PolicyTest.Fixtures.GenericActionPolicyTest do
  @moduledoc false
  use AshGrant.PolicyTest

  resource(AshGrant.Test.ServiceRequest)

  # Actor with specific generic action permissions (by name)
  actor(:operator, %{
    permissions: ["service_request:*:ping:always", "service_request:*:check_status:always"]
  })

  # Actor with only ping permission
  actor(:ping_only, %{permissions: ["service_request:*:ping:always"]})
  # Actor with CRUD but no generic action permission
  actor(:crud_only, %{
    permissions: ["service_request:*:read:always", "service_request:*:create:always"]
  })

  # Actor with deny on specific generic action
  actor(:denied_ping, %{
    permissions: ["service_request:*:ping:always", "!service_request:*:ping:always"]
  })

  # No permissions at all
  actor(:nobody, %{permissions: []})

  describe "generic action access by name" do
    test "operator can ping" do
      assert_can(:operator, :ping)
    end

    test "operator can check_status" do
      assert_can(:operator, :check_status)
    end

    test "ping_only can ping" do
      assert_can(:ping_only, :ping)
    end

    test "ping_only cannot check_status" do
      assert_cannot(:ping_only, :check_status)
    end
  end

  describe "CRUD permission does not grant generic action access" do
    test "crud_only cannot ping" do
      assert_cannot(:crud_only, :ping)
    end

    test "crud_only cannot check_status" do
      assert_cannot(:crud_only, :check_status)
    end

    test "crud_only can read" do
      assert_can(:crud_only, :read)
    end
  end

  describe "deny-wins for generic actions" do
    test "denied_ping cannot ping" do
      assert_cannot(:denied_ping, :ping)
    end

    test "nobody cannot ping" do
      assert_cannot(:nobody, :ping)
    end
  end
end

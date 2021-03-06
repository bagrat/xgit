defmodule Xgit.Repository.DefaultWorkingTreeTest do
  use ExUnit.Case, async: true

  alias Xgit.Repository.InMemory
  alias Xgit.Repository.Storage
  alias Xgit.Repository.WorkingTree
  alias Xgit.Test.TempDirTestCase

  # We use InMemory repository because OnDisk will create its own WorkingTree
  # by default.

  describe "default_working_tree/1" do
    test "happy path" do
      {:ok, repo} = InMemory.start_link()

      assert Storage.default_working_tree(repo) == nil

      # Create a working tree and assign it.

      %{tmp_dir: path} = TempDirTestCase.tmp_dir!()

      {:ok, working_tree} = WorkingTree.start_link(repo, path)

      assert :ok = Storage.set_default_working_tree(repo, working_tree)
      assert Storage.default_working_tree(repo) == working_tree

      # Kids, don't try this at home.

      {:ok, working_tree2} = WorkingTree.start_link(repo, path)
      assert :error = Storage.set_default_working_tree(repo, working_tree2)
      assert Storage.default_working_tree(repo) == working_tree

      # Ensure working tree dies with repo.

      :ok = GenServer.stop(repo)
      refute Process.alive?(repo)

      Process.sleep(20)
      refute Process.alive?(working_tree)
    end

    test "rejects a process that isn't a WorkingTree" do
      {:ok, repo} = InMemory.start_link()
      {:ok, not_working_tree} = GenServer.start_link(NotValid, nil)

      assert :error = Storage.set_default_working_tree(repo, not_working_tree)
    end
  end
end

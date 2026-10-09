defmodule Butler.Commands.SubmitTest do
  use ExUnit.Case, async: false

  alias Butler.Commands.Submit
  alias Butler.Jobs.Job
  alias Butler.Jobs.Queue
  alias Butler.Test.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Engine.start_queue!(tmp)
    :ok
  end

  test "mine enqueues a validated payload without blank options" do
    input = %{dir: "/synthetic/project", mode: "convos", wing: nil, dry_run: true, limit: 3}
    input = Map.merge(input, %{no_gitignore: false, include_ignored: [], agent: nil})

    assert {:ok, %Job{kind: "mine", state: :queued, payload: payload}} = Submit.mine(input)

    assert payload == %{
             "source" => "/synthetic/project",
             "mode" => "convos",
             "dry_run" => true,
             "limit" => 3
           }
  end

  test "sweep enqueues the target" do
    assert {:ok, %Job{kind: "sweep", payload: %{"target" => "/synthetic/t"}}} =
             Submit.sweep(%{target: "/synthetic/t"})
  end

  test "sync is a dry run unless applied" do
    assert {:ok, %Job{payload: %{"dry_run" => true}}} = Submit.sync(%{wing: "w", roots: []})

    assert {:ok, %Job{payload: %{"dry_run" => false, "wing" => "w"}}} =
             Submit.sync(%{wing: "w", roots: []}, apply: true)
  end

  test "applying a sync without scope is refused by validation" do
    assert {:error, {:invalid, "dry_run", _}} = Submit.sync(%{wing: nil, roots: []}, apply: true)
    assert {:ok, []} = Queue.list(Queue)
  end

  test "an identical active job is reported as a duplicate" do
    {:ok, first} = Submit.sweep(%{target: "/synthetic/t"})
    assert {:error, {:duplicate, %Job{id: id}}} = Submit.sweep(%{target: "/synthetic/t"})
    assert id == first.id
    assert {:ok, _other} = Submit.sweep(%{target: "/synthetic/other"})
  end

  test "maintenance jobs" do
    assert {:ok, %Job{kind: "repair", payload: %{"dry_run" => false}}} =
             Submit.maintenance("repair")

    assert {:ok, %Job{kind: "compress", payload: %{"dry_run" => true, "wing" => "w"}}} =
             Submit.maintenance("compress", dry_run: true, wing: "w")
  end

  test "refuses invalid input" do
    assert {:error, {:invalid, "source", _}} = Submit.mine(%{dir: "relative"})
    assert {:error, :unknown_kind} = Submit.maintenance("format-disk")
  end
end

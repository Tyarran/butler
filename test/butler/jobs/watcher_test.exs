defmodule Butler.Jobs.WatcherTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Watcher

  setup do
    topic = "butler:queue:test:#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> :first end)
    :ok = Phoenix.PubSub.subscribe(Butler.PubSub, topic)

    start_supervised!(
      {Watcher,
       name: nil,
       topic: topic,
       poll_interval_ms: 10,
       snapshot_fun: fn -> Agent.get(agent, & &1) end}
    )

    {:ok, agent: agent}
  end

  test "broadcasts the initial snapshot" do
    assert_receive {:queue_changed, :first}, 500
  end

  test "does not broadcast again while nothing changes" do
    assert_receive {:queue_changed, :first}, 500
    refute_receive {:queue_changed, _}, 150
  end

  test "broadcasts when the snapshot changes", %{agent: agent} do
    assert_receive {:queue_changed, :first}, 500

    Agent.update(agent, fn _ -> :second end)
    assert_receive {:queue_changed, :second}, 500
    refute_receive {:queue_changed, _}, 100

    Agent.update(agent, fn _ -> :first end)
    assert_receive {:queue_changed, :first}, 500
  end

  test "default topic and polling interval are exposed" do
    assert Watcher.topic() == "butler:queue"
    assert Watcher.poll_interval_ms() == 2_000
  end

  test "the watcher is disabled in the test environment" do
    assert Application.fetch_env!(:butler, :start_watcher) == false
    assert Process.whereis(Watcher) == nil
  end
end

defmodule Butler.MaintenanceTest do
  # The flag is global (named ETS table): no concurrency.
  use ExUnit.Case, async: false

  alias Butler.Maintenance

  setup do
    Maintenance.subscribe()
    on_exit(&Maintenance.leave/0)
    :ok
  end

  test "is off by default" do
    refute Maintenance.active?()
    assert Maintenance.state() == :inactive
    assert Maintenance.job_id() == nil
  end

  test "enter/1 and leave/0 flip the flag and broadcast the change once" do
    assert Maintenance.enter("job-1") == :ok
    assert Maintenance.active?()
    assert Maintenance.state() == :active
    assert Maintenance.job_id() == "job-1"
    assert_receive {:maintenance_changed, :active}

    assert Maintenance.enter("job-1") == :ok
    refute_received {:maintenance_changed, _state}

    assert Maintenance.leave() == :ok
    refute Maintenance.active?()
    assert Maintenance.job_id() == nil
    assert_receive {:maintenance_changed, :inactive}
  end

  test "leave/0 is idempotent and silent when already off" do
    assert Maintenance.leave() == :ok
    assert Maintenance.leave() == :ok
    refute_received {:maintenance_changed, _state}
  end

  test "the table is readable by any process without calling the server" do
    Maintenance.enter(nil)
    test = self()
    spawn_link(fn -> send(test, {:seen, Maintenance.active?()}) end)
    assert_receive {:seen, true}
  end
end

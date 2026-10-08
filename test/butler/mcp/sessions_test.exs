defmodule Butler.MCP.SessionsTest do
  use ExUnit.Case, async: true

  alias Butler.MCP.Sessions

  defp start_store!(opts \\ []) do
    name = :"sessions_#{System.unique_integer([:positive])}"
    start_supervised!({Sessions, Keyword.put(opts, :name, name)})
    name
  end

  test "create/2 returns a unique opaque id bound to a backend" do
    table = start_store!()

    a = Sessions.create(:light, table)
    b = Sessions.create(:light, table)

    assert a != b
    assert a =~ ~r/\A[A-Za-z0-9_-]{20,}\z/
    assert Sessions.validate(a, :light, table) == :ok
  end

  test "validate/3 rejects unknown ids, non-strings and other backends" do
    table = start_store!()
    id = Sessions.create(:light, table)

    assert Sessions.validate("unknown", :light, table) == :error
    assert Sessions.validate(nil, :light, table) == :error
    assert Sessions.validate(id, :full, table) == :error
  end

  test "delete/2 ends a session" do
    table = start_store!()
    id = Sessions.create(:light, table)

    assert Sessions.delete(id, table) == :ok
    assert Sessions.validate(id, :light, table) == :error
    assert Sessions.delete(id, table) == :ok
  end

  test "count/2 counts live sessions per backend" do
    table = start_store!()
    Sessions.create(:light, table)
    Sessions.create(:light, table)
    Sessions.create(:full, table)

    assert Sessions.count(:light, table) == 2
    assert Sessions.count(:full, table) == 1
  end

  test "an expired session is rejected, deleted and not counted" do
    table = start_store!(ttl_ms: 0)
    id = Sessions.create(:light, table)

    # Both reads are strictly later than the creation.
    receive do
    after
      5 -> :ok
    end

    assert Sessions.count(:light, table) == 0
    assert Sessions.validate(id, :light, table) == :error
  end

  test "the purge removes expired sessions" do
    table = start_store!(ttl_ms: 0, purge_interval_ms: 10_000)
    Sessions.create(:light, table)

    receive do
    after
      5 -> :ok
    end

    send(Process.whereis(table), :purge)
    _ = :sys.get_state(table)

    assert :ets.select_count(table, [{{:"$1", :light, :_}, [], [true]}]) == 0
  end
end

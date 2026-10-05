defmodule Butler.Daemon.LocatorTest do
  use ExUnit.Case, async: true

  alias Butler.Daemon.Locator
  alias Butler.Test.QueueFixture

  @palace "/tmp/synthetic/palace"
  @secret "SECRET-TOKEN-MARKER"

  setup do
    {:ok, root: QueueFixture.tmp_dir!()}
  end

  defp daemon_dir!(root, id, endpoint, opts \\ []) do
    dir = Path.join(root, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "endpoint.json"), Jason.encode!(endpoint))

    token = Path.join(dir, "token")
    File.write!(token, @secret)
    # Any attempt to read the token would fail loudly.
    File.chmod!(token, 0o000)
    ExUnit.Callbacks.on_exit(fn -> File.chmod(token, 0o600) end)

    if opts[:queue], do: QueueFixture.create!(Path.join(dir, "queue.sqlite3"))
    dir
  end

  defp endpoint(overrides \\ %{}) do
    Map.merge(
      %{
        "host" => "127.0.0.1",
        "port" => 4242,
        "pid" => 1234,
        "palace_path" => @palace,
        "started_at" => "2026-01-01T10:00:00+00:00"
      },
      overrides
    )
  end

  test "finds the state directory matching the palace path", %{root: root} do
    dir = daemon_dir!(root, "aaa", endpoint())
    daemon_dir!(root, "bbb", endpoint(%{"palace_path" => "/tmp/other/palace"}))

    assert {:ok, found} = Locator.find(root, @palace)
    assert found.dir == dir
    assert found.queue_path == Path.join(dir, "queue.sqlite3")
    assert found.pid == 1234
    assert found.palace_path == @palace
    assert found.started_at == ~U[2026-01-01 10:00:00Z]
  end

  test "with several matches, picks the latest started_at", %{root: root} do
    daemon_dir!(root, "old", endpoint(%{"started_at" => "2026-01-01T10:00:00+00:00"}))
    new = daemon_dir!(root, "new", endpoint(%{"started_at" => "2026-02-01T10:00:00+00:00"}))
    daemon_dir!(root, "mid", endpoint(%{"started_at" => "2026-01-15T10:00:00+00:00"}))

    assert {:ok, %{dir: ^new}} = Locator.find(root, @palace)
  end

  test "never reads the token file and never exposes its content", %{root: root} do
    daemon_dir!(root, "aaa", endpoint())

    assert {:ok, found} = Locator.find(root, @palace)
    refute inspect(found) =~ @secret
    refute Map.has_key?(found, :token)
  end

  test "returns {:error, :not_found} when no directory matches", %{root: root} do
    daemon_dir!(root, "aaa", endpoint(%{"palace_path" => "/tmp/other"}))
    assert Locator.find(root, @palace) == {:error, :not_found}
  end

  test "returns {:error, :not_found} when the root does not exist" do
    assert Locator.find("/nonexistent/butler/daemon", @palace) == {:error, :not_found}
  end

  test "skips directories with a missing or malformed endpoint.json", %{root: root} do
    File.mkdir_p!(Path.join(root, "empty"))
    bad = Path.join(root, "bad")
    File.mkdir_p!(bad)
    File.write!(Path.join(bad, "endpoint.json"), "{nope")
    good = daemon_dir!(root, "good", endpoint())

    assert {:ok, %{dir: ^good}} = Locator.find(root, @palace)
  end

  describe "stopped daemon (no endpoint.json)" do
    # Computed with the daemon's own algorithm:
    # sha256(abspath(realpath(palace)))[:24]
    @key "487553a8cf2262446d9ed427"

    test "palace_key/1 matches the daemon's directory naming" do
      assert Locator.palace_key("/tmp/bthrow/palace") == @key
    end

    test "falls back to the directory named after the palace key", %{root: root} do
      dir = Path.join(root, @key)
      QueueFixture.create!(Path.join(dir, "queue.sqlite3"))

      assert {:ok, found} = Locator.find(root, "/tmp/bthrow/palace")
      assert found.dir == dir
      assert found.queue_path == Path.join(dir, "queue.sqlite3")
      assert found.pid == nil
      assert found.started_at == nil
    end

    test "is not found when neither endpoint nor keyed directory exist", %{root: root} do
      assert Locator.find(root, "/tmp/bthrow/palace") == {:error, :not_found}
    end
  end

  test "ignores a trailing slash difference in the palace path", %{root: root} do
    daemon_dir!(root, "aaa", endpoint(%{"palace_path" => @palace <> "/"}))
    assert {:ok, _} = Locator.find(root, @palace)
  end
end

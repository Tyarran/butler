defmodule Butler.PathsTest do
  use ExUnit.Case, async: false

  alias Butler.Paths

  setup do
    previous_env = Application.fetch_env(:butler, :state_dir)
    previous_xdg = System.get_env("XDG_STATE_HOME")

    on_exit(fn ->
      case previous_env do
        {:ok, value} -> Application.put_env(:butler, :state_dir, value)
        :error -> Application.delete_env(:butler, :state_dir)
      end

      if previous_xdg,
        do: System.put_env("XDG_STATE_HOME", previous_xdg),
        else: System.delete_env("XDG_STATE_HOME")
    end)
  end

  test "state_dir/0 uses the configured BUTLER_STATE_DIR first" do
    Application.put_env(:butler, :state_dir, "/tmp/butler-synthetic/state")
    System.put_env("XDG_STATE_HOME", "/tmp/butler-synthetic/xdg")

    assert Paths.state_dir() == "/tmp/butler-synthetic/state"
  end

  test "state_dir/0 falls back to XDG_STATE_HOME/butler" do
    Application.delete_env(:butler, :state_dir)
    System.put_env("XDG_STATE_HOME", "/tmp/butler-synthetic/xdg")

    assert Paths.state_dir() == "/tmp/butler-synthetic/xdg/butler"
  end

  test "state_dir/0 falls back to ~/.local/state/butler" do
    Application.put_env(:butler, :state_dir, "")
    System.delete_env("XDG_STATE_HOME")

    assert Paths.state_dir() == Path.expand("~/.local/state/butler")
  end

  test "queue and token live in the state dir, never in the Python daemon dir" do
    Application.put_env(:butler, :state_dir, "/tmp/butler-synthetic/state")

    assert Paths.queue_path() == "/tmp/butler-synthetic/state/queue.sqlite3"
    assert Paths.token_path() == "/tmp/butler-synthetic/state/token"
    refute Paths.state_dir() =~ ".mempalace"
  end

  @tag :tmp_dir
  test "ensure_dir/1 creates the directory with mode 700", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "a/b/state")

    assert Paths.ensure_dir(dir) == :ok
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
  end
end

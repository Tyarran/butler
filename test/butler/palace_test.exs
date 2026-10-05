defmodule Butler.PalaceTest do
  use ExUnit.Case, async: false

  alias Butler.Palace

  @keys [:palace_path, :mempalace_home, :mempalace_bin]

  setup do
    previous = Enum.map(@keys, &{&1, Application.fetch_env(:butler, &1)})

    on_exit(fn ->
      for {key, result} <- previous do
        case result do
          {:ok, value} -> Application.put_env(:butler, key, value)
          :error -> Application.delete_env(:butler, key)
        end
      end
    end)
  end

  test "path/0 returns the configured palace path" do
    Application.put_env(:butler, :palace_path, "/tmp/some/palace")
    assert Palace.path() == "/tmp/some/palace"
  end

  test "mempalace_home/0 returns the configured MemPalace home" do
    Application.put_env(:butler, :mempalace_home, "/tmp/home/.mempalace")
    assert Palace.mempalace_home() == "/tmp/home/.mempalace"
  end

  test "daemon_root/0 is the daemon directory under the MemPalace home" do
    Application.put_env(:butler, :mempalace_home, "/tmp/home/.mempalace")
    assert Palace.daemon_root() == "/tmp/home/.mempalace/daemon"
  end

  test "mempalace_bin/0 returns the configured binary" do
    Application.put_env(:butler, :mempalace_bin, "/opt/bin/mempalace")
    assert Palace.mempalace_bin() == "/opt/bin/mempalace"
  end

  test "falls back to defaults when nothing is configured" do
    for key <- @keys, do: Application.delete_env(:butler, key)

    assert Palace.path() == Path.expand("~/.config/mempalace/palace")
    assert Palace.mempalace_home() == Path.expand("~/.mempalace")
    assert Palace.mempalace_bin() == "mempalace"
  end
end

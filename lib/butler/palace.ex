defmodule Butler.Palace do
  @moduledoc """
  Configuration of the MemPalace installation Butler watches.

  Butler monitors a single palace. Values are read from the `:butler`
  application environment, which `config/runtime.exs` fills from:

    * `BUTLER_PALACE_PATH` - palace directory
      (default `~/.config/mempalace/palace`)
    * `BUTLER_MEMPALACE_HOME` - MemPalace state home (default `~/.mempalace`)
    * `BUTLER_MEMPALACE_BIN` - `mempalace` executable (default `mempalace`,
      resolved through `PATH`)
  """

  @default_palace_path "~/.config/mempalace/palace"
  @default_mempalace_home "~/.mempalace"
  @default_mempalace_bin "mempalace"
  @daemon_dir "daemon"

  @doc "Absolute path of the monitored palace."
  @spec path() :: Path.t()
  def path do
    :butler
    |> Application.get_env(:palace_path, @default_palace_path)
    |> Path.expand()
  end

  @doc "Absolute path of the MemPalace state home (`~/.mempalace` by default)."
  @spec mempalace_home() :: Path.t()
  def mempalace_home do
    :butler
    |> Application.get_env(:mempalace_home, @default_mempalace_home)
    |> Path.expand()
  end

  @doc "Directory holding one state directory per daemon (`<home>/daemon`)."
  @spec daemon_root() :: Path.t()
  def daemon_root, do: Path.join(mempalace_home(), @daemon_dir)

  @doc "The `mempalace` executable, as a name resolved through `PATH` or a path."
  @spec mempalace_bin() :: String.t()
  def mempalace_bin, do: Application.get_env(:butler, :mempalace_bin, @default_mempalace_bin)
end

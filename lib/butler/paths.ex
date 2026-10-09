defmodule Butler.Paths do
  @moduledoc """
  Locations of Butler's **own** state.

  Butler keeps its queue database and API token in a private state directory,
  never in the MemPalace daemon directory. The directory is, in order:

    * `BUTLER_STATE_DIR` (application env `:state_dir`, filled by
      `config/runtime.exs`)
    * `$XDG_STATE_HOME/butler`
    * `~/.local/state/butler`

  The directory has mode 700; the queue database (with its `-wal` and `-shm`
  files) and the token have mode 600.
  """

  @app_dir "butler"
  @queue_file "queue.sqlite3"
  @token_file "token"
  @dir_mode 0o700
  @file_mode 0o600

  @doc "Absolute path of the state directory (not created)."
  @spec state_dir() :: Path.t()
  def state_dir do
    case Application.get_env(:butler, :state_dir) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _unset -> default_state_dir()
    end
  end

  @doc "Path of Butler's queue database."
  @spec queue_path() :: Path.t()
  def queue_path, do: Path.join(state_dir(), @queue_file)

  @doc "Path of Butler's API token file."
  @spec token_path() :: Path.t()
  def token_path, do: Path.join(state_dir(), @token_file)

  @doc "Mode of the state directory."
  @spec dir_mode() :: non_neg_integer()
  def dir_mode, do: @dir_mode

  @doc "Mode of the files in the state directory."
  @spec file_mode() :: non_neg_integer()
  def file_mode, do: @file_mode

  @doc """
  Creates `dir` (parents included) and sets its mode to 700.
  """
  @spec ensure_dir(Path.t()) :: :ok | {:error, File.posix()}
  def ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, @dir_mode)
    end
  end

  defp default_state_dir do
    case System.get_env("XDG_STATE_HOME") do
      xdg when is_binary(xdg) and xdg != "" -> Path.join(Path.expand(xdg), @app_dir)
      _unset -> Path.expand(Path.join(["~", ".local", "state", @app_dir]))
    end
  end
end

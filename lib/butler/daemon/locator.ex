defmodule Butler.Daemon.Locator do
  @moduledoc """
  Finds the daemon state directory (`~/.mempalace/daemon/<id>/`) of a palace.

  The directory is identified by matching `palace_path` in each
  `endpoint.json`. **Only `endpoint.json` is ever read**: the `token` file
  next to it is a secret and is never opened. Multiple matches (stale
  directories) resolve to the one with the latest `started_at`.
  """

  alias Butler.Palace

  @endpoint_file "endpoint.json"
  @queue_file "queue.sqlite3"
  @key_length 24

  defstruct [:dir, :queue_path, :pid, :palace_path, :started_at, :host, :port]

  @type t :: %__MODULE__{
          dir: Path.t(),
          queue_path: Path.t(),
          pid: non_neg_integer() | nil,
          palace_path: Path.t(),
          started_at: DateTime.t() | nil,
          host: String.t() | nil,
          port: non_neg_integer() | nil
        }

  @doc """
  Locates the daemon state directory for `palace_path` under `root`
  (defaults to the configured daemon root and palace).

  A running daemon is found through its `endpoint.json`. A cleanly stopped
  daemon removes `endpoint.json` but leaves its directory (and queue) behind,
  so the directory named after `palace_key/1` is used as a fallback; the
  result then has no `pid` nor `started_at`.
  """
  @spec find(Path.t(), Path.t()) :: {:ok, t()} | {:error, :not_found}
  def find(root \\ Palace.daemon_root(), palace_path \\ Palace.path()) do
    wanted = normalize(palace_path)

    root
    |> list_dirs()
    |> Enum.map(&read_endpoint/1)
    |> Enum.filter(&matches?(&1, wanted))
    |> Enum.max_by(&sort_key/1, DateTime, fn -> nil end)
    |> case do
      nil -> find_by_key(root, wanted)
      found -> {:ok, found}
    end
  end

  @doc """
  Name of the daemon state directory of a palace, computed like the daemon
  does: the first 24 hex characters of the SHA-256 of the palace path.

  Symlinks are not resolved here, unlike the daemon (`realpath`): a palace
  reached through a symlink is still found through `endpoint.json` while
  running.
  """
  @spec palace_key(Path.t()) :: String.t()
  def palace_key(palace_path) do
    :sha256
    |> :crypto.hash(normalize(palace_path))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @key_length)
  end

  defp find_by_key(root, wanted) do
    dir = Path.join(root, palace_key(wanted))

    if File.dir?(dir) do
      {:ok,
       %__MODULE__{
         dir: dir,
         queue_path: Path.join(dir, @queue_file),
         palace_path: wanted
       }}
    else
      {:error, :not_found}
    end
  end

  defp list_dirs(root) do
    case File.ls(root) do
      {:ok, names} -> names |> Enum.map(&Path.join(root, &1)) |> Enum.filter(&File.dir?/1)
      {:error, _reason} -> []
    end
  end

  defp read_endpoint(dir) do
    with {:ok, content} <- File.read(Path.join(dir, @endpoint_file)),
         {:ok, %{"palace_path" => palace_path} = data} when is_binary(palace_path) <-
           Jason.decode(content) do
      %__MODULE__{
        dir: dir,
        queue_path: Path.join(dir, @queue_file),
        pid: integer_or_nil(data["pid"]),
        palace_path: palace_path,
        started_at: parse_datetime(data["started_at"]),
        host: data["host"],
        port: integer_or_nil(data["port"])
      }
    else
      _ -> nil
    end
  end

  defp sort_key(%__MODULE__{started_at: nil}), do: ~U[1970-01-01 00:00:00Z]
  defp sort_key(%__MODULE__{started_at: started_at}), do: started_at

  defp matches?(%__MODULE__{palace_path: palace_path}, wanted),
    do: normalize(palace_path) == wanted

  defp matches?(nil, _wanted), do: false

  defp normalize(path), do: Path.expand(path)

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end

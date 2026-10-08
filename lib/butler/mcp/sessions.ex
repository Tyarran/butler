defmodule Butler.MCP.Sessions do
  @moduledoc """
  The client sessions of the MCP proxy (`Mcp-Session-Id`).

  Sessions belong to Butler, not to a backend process: they survive the
  rotation and the crash of the Python processes behind them. Each session is
  bound to the backend it was created on and expires after `:ttl_ms` without
  use.

  State lives in a public ETS table, so request processes read and write it
  directly; this process only owns the table and purges expired sessions.
  """

  use GenServer

  alias Butler.MCP.Backend
  alias Butler.MCP.Config

  @default_name __MODULE__
  @default_purge_interval_ms 60_000
  @ttl_key :__ttl__

  @doc """
  Starts the session store.

  Options: `:name` (default `#{inspect(@default_name)}`, also the ETS table
  name), `:ttl_ms` (default `Butler.MCP.Config.session_ttl_ms/0`) and
  `:purge_interval_ms`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Creates a session on `backend` and returns its id."
  @spec create(Config.backend(), atom()) :: String.t()
  def create(backend, table \\ @default_name) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    :ets.insert(table, {id, backend, now()})
    broadcast(backend)
    id
  end

  @doc """
  Checks that `id` is a live session of `backend` and renews it.

  An expired session is deleted.
  """
  @spec validate(term(), Config.backend(), atom()) :: :ok | :error
  def validate(id, backend, table \\ @default_name)

  def validate(id, backend, table) when is_binary(id) do
    ttl = ttl(table)

    case :ets.lookup(table, id) do
      [{^id, ^backend, last_seen}] ->
        if now() - last_seen <= ttl do
          :ets.insert(table, {id, backend, now()})
          :ok
        else
          delete(id, table)
          :error
        end

      _unknown_or_other_backend ->
        :error
    end
  end

  def validate(_id, _backend, _table), do: :error

  @doc "Deletes the session `id`, if any."
  @spec delete(String.t(), atom()) :: :ok
  def delete(id, table \\ @default_name) do
    case :ets.take(table, id) do
      [{^id, backend, _last_seen}] -> broadcast(backend)
      [] -> :ok
    end
  end

  @doc "Number of live sessions of `backend`."
  @spec count(Config.backend(), atom()) :: non_neg_integer()
  def count(backend, table \\ @default_name) do
    ttl = ttl(table)
    limit = now() - ttl

    :ets.select_count(table, [
      {{:"$1", backend, :"$2"}, [{:>=, :"$2", limit}], [true]}
    ])
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    ttl = Keyword.get_lazy(opts, :ttl_ms, &Config.session_ttl_ms/0)
    interval = Keyword.get(opts, :purge_interval_ms, @default_purge_interval_ms)

    :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(name, {@ttl_key, :config, ttl})
    schedule_purge(interval)

    {:ok, %{table: name, interval: interval}}
  end

  @impl GenServer
  def handle_info(:purge, state) do
    limit = now() - ttl(state.table)

    expired =
      :ets.select(state.table, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", limit}, {:is_binary, :"$1"}], [{{:"$1", :"$2"}}]}
      ])

    Enum.each(expired, fn {id, _backend} -> delete(id, state.table) end)
    schedule_purge(state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ttl(table) do
    [{@ttl_key, :config, ttl}] = :ets.lookup(table, @ttl_key)
    ttl
  end

  defp schedule_purge(interval), do: Process.send_after(self(), :purge, interval)

  defp now, do: System.monotonic_time(:millisecond)

  defp broadcast(backend) do
    Phoenix.PubSub.broadcast(Butler.PubSub, Backend.topic(), {:mcp_changed, backend})
  end
end

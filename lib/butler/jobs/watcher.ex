defmodule Butler.Jobs.Watcher do
  @moduledoc """
  Polls the daemon status and job queue and broadcasts changes over PubSub.

  Every `poll_interval_ms/0` the watcher takes a snapshot (daemon status plus
  a fingerprint of the most recent jobs). Only when the snapshot differs from
  the previous one it broadcasts `{:queue_changed, snapshot}` on `topic/0`
  (`"butler:queue"`), so LiveViews can refresh without polling themselves.

  The watcher only reads (`Butler.Daemon.Status`, `Butler.Jobs.Store`). It is
  not started in the test environment (`config :butler, start_watcher: false`).
  """

  use GenServer

  alias Butler.Daemon.Status
  alias Butler.Jobs.Store

  @poll_interval_ms 2_000
  @topic "butler:queue"
  @fingerprint_jobs 50

  @type snapshot :: term()

  @doc "Starts the watcher. Options: `:name`, `:topic`, `:poll_interval_ms`, `:snapshot_fun`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "PubSub topic the watcher broadcasts on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Default polling interval in milliseconds."
  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms, do: @poll_interval_ms

  @doc "Subscribes the calling process to queue changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Butler.PubSub, @topic)

  @doc "Builds the snapshot compared between polls."
  @spec snapshot() :: snapshot()
  def snapshot do
    status = Status.resolve()

    jobs =
      with path when is_binary(path) <- status.queue_path,
           {:ok, jobs} <- Store.list(path, limit: @fingerprint_jobs) do
        Enum.map(jobs, &{&1.id, &1.state, &1.attempts, &1.finished_at})
      else
        _ -> []
      end

    %{status: status, jobs: jobs}
  end

  @impl GenServer
  def init(opts) do
    state = %{
      topic: Keyword.get(opts, :topic, @topic),
      interval: Keyword.get(opts, :poll_interval_ms, @poll_interval_ms),
      snapshot_fun: Keyword.get(opts, :snapshot_fun, &snapshot/0),
      last: :none
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    current = state.snapshot_fun.()

    if current != state.last do
      Phoenix.PubSub.broadcast(Butler.PubSub, state.topic, {:queue_changed, current})
    end

    Process.send_after(self(), :poll, state.interval)
    {:noreply, %{state | last: current}}
  end
end

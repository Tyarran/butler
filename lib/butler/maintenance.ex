defmodule Butler.Maintenance do
  @moduledoc """
  The maintenance flag: whether a `repair`, `compress` or `migrate-wings` job
  owns the palace.

  While it is active, the MCP proxy answers every request (but notifications)
  at once with a JSON-RPC error and never checks a worker out. The flag lives
  in a named ETS table (`read_concurrency`), so that the proxy reads it
  without going through a process; only this server writes it, and the job
  worker is its only client (`enter/1`, `leave/0`).

  `leave/0` is idempotent. Changes are broadcast as
  `{:maintenance_changed, state}` (`:active` or `:inactive`) on the
  `"butler:worker"` topic.
  """

  use GenServer

  @table :butler_maintenance
  @topic "butler:worker"

  @type state :: :active | :inactive

  @doc "Starts the server and creates the ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether maintenance mode is on. `false` when the server is not running."
  @spec active?() :: boolean()
  def active? do
    :ets.lookup(@table, :state) == [state: :active]
  rescue
    ArgumentError -> false
  end

  @doc "The current state."
  @spec state() :: state()
  def state, do: if(active?(), do: :active, else: :inactive)

  @doc "The id of the job that owns the maintenance, if any."
  @spec job_id() :: String.t() | nil
  def job_id do
    case :ets.lookup(@table, :job_id) do
      [job_id: id] -> id
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Turns maintenance mode on for `job_id`. Returns `:ok`, even when it already was on."
  @spec enter(String.t() | nil) :: :ok
  def enter(job_id \\ nil), do: GenServer.call(__MODULE__, {:enter, job_id})

  @doc "Turns maintenance mode off. Idempotent; `:ok` when the server is gone."
  @spec leave() :: :ok
  def leave do
    GenServer.call(__MODULE__, :leave)
  catch
    :exit, _reason -> :ok
  end

  @doc "The PubSub topic of `{:maintenance_changed, state}` messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to maintenance changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Butler.PubSub, @topic)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(@table, [{:state, :inactive}, {:job_id, nil}])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:enter, job_id}, _from, state) do
    changed? = not active?()
    :ets.insert(@table, [{:job_id, job_id}, {:state, :active}])
    if changed?, do: broadcast(:active)
    {:reply, :ok, state}
  end

  def handle_call(:leave, _from, state) do
    changed? = active?()
    :ets.insert(@table, [{:state, :inactive}, {:job_id, nil}])
    if changed?, do: broadcast(:inactive)
    {:reply, :ok, state}
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Butler.PubSub, @topic, {:maintenance_changed, state})
  end
end

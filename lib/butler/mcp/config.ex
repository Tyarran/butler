defmodule Butler.MCP.Config do
  @moduledoc """
  Configuration of the MCP proxy.

  Values are read from the `:mcp` key of the `:butler` application
  environment, which `config/runtime.exs` fills from:

    * `BUTLER_MCP_ENABLED` - `false` disables the proxy (default: enabled)
    * `BUTLER_MCP_ROTATION_MINUTES` - idle delay before a backend process is
      recycled (default `10`)
    * `BUTLER_MCP_FULL_BIN` - `mempalace-mcp` executable
    * `BUTLER_MCP_LIGHT_BIN` - `mempalace-light-mcp` executable

  The palace served by the backends is always the one of `Butler.Palace`.
  """

  alias Butler.Palace

  @backends [:full, :light]
  @default_bins %{full: "mempalace-mcp", light: "mempalace-light-mcp"}
  @default_idle_rotation_ms 600_000
  @default_max_start_failures 3
  @default_request_timeout_ms 120_000
  @default_startup_timeout_ms 60_000
  @default_session_ttl_ms 3_600_000

  @typedoc "Identifier of an MCP backend."
  @type backend :: :full | :light

  @doc "The backends the proxy serves."
  @spec backends() :: [backend()]
  def backends, do: @backends

  @doc "Whether `term` is a known backend identifier."
  @spec backend?(term()) :: boolean()
  def backend?(term), do: term in @backends

  @doc "Whether the proxy starts with the application (`:start_mcp`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:butler, :start_mcp, true)

  @doc "Idle delay, in milliseconds, after which the active process is rotated."
  @spec idle_rotation_ms() :: pos_integer()
  def idle_rotation_ms, do: get(:idle_rotation_ms, @default_idle_rotation_ms)

  @doc "Consecutive start failures after which a backend is marked failed."
  @spec max_start_failures() :: pos_integer()
  def max_start_failures, do: get(:max_start_failures, @default_max_start_failures)

  @doc "Time, in milliseconds, a backend may take to answer one request."
  @spec request_timeout_ms() :: pos_integer()
  def request_timeout_ms, do: get(:request_timeout_ms, @default_request_timeout_ms)

  @doc "Time, in milliseconds, a process may take to complete its handshake."
  @spec startup_timeout_ms() :: pos_integer()
  def startup_timeout_ms, do: get(:startup_timeout_ms, @default_startup_timeout_ms)

  @doc "Inactivity, in milliseconds, after which a client session expires."
  @spec session_ttl_ms() :: pos_integer()
  def session_ttl_ms, do: get(:session_ttl_ms, @default_session_ttl_ms)

  @doc "The executable of `backend`, as a name resolved through `PATH` or a path."
  @spec bin(backend()) :: String.t()
  def bin(backend) when backend in @backends do
    :mcp
    |> env()
    |> Keyword.get(:backends, %{})
    |> Map.get(backend, [])
    |> Keyword.get(:bin, Map.fetch!(@default_bins, backend))
  end

  @doc "The argument list `backend` is started with: it serves the Butler palace."
  @spec args(backend()) :: [String.t()]
  def args(backend) when backend in @backends, do: ["--palace", Palace.path()]

  defp get(key, default), do: :mcp |> env() |> Keyword.get(key, default)

  defp env(key), do: Application.get_env(:butler, key, [])
end

defmodule Butler.Jobs.Runner.MCP do
  @moduledoc """
  Runs a write MCP job kind through the persistent `Butler.MCP.Writer`.

    * `mcp_tool` - payload `name` (in `Butler.MCP.Tools.write_tools/0`) and
      `arguments` (a map, default `%{}`);
    * `diary_write` - payload `agent_name`, `entry`, `topic` (default
      `"general"`) and `wing`; it calls `mempalace_diary_write`.

  Outcomes are those of `Butler.Jobs.Runner.CLI`. A call is never retried. It
  is a failure when the JSON-RPC answer is an error, when the result has
  `isError`, or when the tool's JSON payload has `"success": false` or an
  `"error"` key. A palace-lock refusal (JSON-RPC code -32001 / failure kind
  `peer_contention`, or the lock-refusal text) is `{:lock_refused, text}`. A
  timeout kills the writer and fails the job.
  """

  alias Butler.Jobs.Job
  alias Butler.Jobs.Runner.CLI, as: CLIRunner
  alias Butler.MCP.Tools
  alias Butler.MCP.Writer

  @default_topic "general"
  @lock_code -32_001
  @diary_keys ~w(agent_name entry topic wing)

  @type outcome :: CLIRunner.outcome()

  @doc """
  Runs `job`. Options: `:writer` (server, default `Butler.MCP.Writer`),
  `:timeout_ms`, `:on_start` (called with the writer's OS pid),
  `:write_tools` (allowlist override, for tests with the fake backend).
  """
  @spec run(Job.t(), keyword()) :: outcome()
  def run(%Job{kind: kind, payload: payload}, opts \\ []) do
    case request(kind, payload || %{}, Keyword.get(opts, :write_tools, Tools.write_tools())) do
      {:ok, name, arguments} -> call(name, arguments, opts)
      {:error, message} -> {:error, %{class: "InvalidPayload", message: message}}
    end
  end

  @doc """
  The `{tool name, arguments}` a job of `kind` with `payload` calls, or an
  error message. Pure: nothing is started.
  """
  @spec request(String.t(), map(), [String.t()]) ::
          {:ok, String.t(), map()} | {:error, String.t()}
  def request(kind, payload, write_tools \\ Tools.write_tools())

  def request("mcp_tool", %{} = payload, write_tools) do
    with {:ok, payload} <- only(payload, ~w(name arguments)),
         name = Map.get(payload, "name"),
         true <-
           name in write_tools || {:error, "tool is not in the write allowlist: #{inspect(name)}"},
         {:ok, arguments} <- arguments(Map.get(payload, "arguments")) do
      {:ok, name, arguments}
    end
  end

  def request("diary_write", %{} = payload, _write_tools) do
    with {:ok, payload} <- only(payload, @diary_keys),
         {:ok, agent} <- text(payload, "agent_name", true),
         {:ok, entry} <- text(payload, "entry", true),
         {:ok, topic} <- text(payload, "topic", false),
         {:ok, wing} <- text(payload, "wing", false) do
      args = %{"agent_name" => agent, "entry" => entry, "topic" => topic || @default_topic}
      {:ok, "mempalace_diary_write", if(wing, do: Map.put(args, "wing", wing), else: args)}
    end
  end

  def request(kind, _payload, _write_tools), do: {:error, "unsupported kind: #{inspect(kind)}"}

  defp only(payload, allowed) do
    payload = Map.new(payload, fn {key, value} -> {to_string(key), value} end)

    case Enum.find(Map.keys(payload), &(&1 not in allowed)) do
      nil -> {:ok, payload}
      key -> {:error, "unknown payload key: #{key}"}
    end
  end

  defp arguments(nil), do: {:ok, %{}}
  defp arguments(%{} = arguments), do: {:ok, arguments}
  defp arguments(_other), do: {:error, "arguments must be an object"}

  defp text(payload, key, required?) do
    case Map.get(payload, key) do
      nil when not required? -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp call(name, arguments, opts) do
    writer = Keyword.get(opts, :writer, Writer)
    call_opts = Keyword.take(opts, [:timeout_ms, :on_start])

    case Writer.call_tool(writer, name, arguments, call_opts) do
      {:ok, answer} -> classify(name, answer)
      {:error, :timeout} -> timeout(opts)
      {:error, reason} -> {:error, %{class: "MCPError", message: describe(reason)}}
    end
  end

  defp timeout(opts) do
    seconds = opts |> Keyword.get(:timeout_ms, 0) |> div(1000)
    {:error, %{class: "Timeout", message: "MCP tool timed out after #{seconds}s; writer stopped"}}
  end

  defp describe({:start_failed, reason}), do: "MCP writer failed to start: #{inspect(reason)}"
  defp describe({:backend_exited, status}), do: "MCP writer exited (status #{status})"
  defp describe(reason), do: "MCP writer unavailable: #{inspect(reason)}"

  defp classify(_name, %{"error" => %{} = error}) do
    message = to_string(error["message"])

    if error["code"] == @lock_code or get_in(error, ["data", "failure_kind"]) == "peer_contention" or
         CLIRunner.lock_refused?(message) do
      {:lock_refused, message}
    else
      {:error, %{class: "MCPError", message: message, code: error["code"]}}
    end
  end

  defp classify(name, %{"result" => %{} = result}) do
    text = result |> Map.get("content", []) |> texts()
    payload = decode(text)

    cond do
      CLIRunner.lock_refused?(text) -> {:lock_refused, text}
      result["isError"] == true -> failure(text, payload)
      failed?(payload) -> failure(text, payload)
      true -> {:ok, %{tool: name, result: payload || text}}
    end
  end

  defp classify(_name, _answer),
    do: {:error, %{class: "MCPError", message: "malformed MCP answer"}}

  defp texts(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp texts(_other), do: ""

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> map
      _other -> nil
    end
  end

  defp failed?(%{"success" => false}), do: true
  defp failed?(%{"error" => _error}), do: true
  defp failed?(_other), do: false

  defp failure(text, payload) do
    message =
      case payload do
        %{"error" => error} when is_binary(error) -> error
        _other -> text
      end

    {:error, %{class: "MCPToolFailed", message: message, output_tail: text}}
  end
end

defmodule Butler.MCP.Protocol do
  @moduledoc """
  Pure helpers for the JSON-RPC 2.0 messages the MCP proxy relays.

  Nothing here does I/O: messages are decoded maps, and the stdio wire format
  is one JSON object per line.
  """

  @jsonrpc "2.0"
  @protocol_version "2025-06-18"
  @parse_error -32_700
  @invalid_request -32_600
  @internal_error -32_603

  @typedoc "A decoded JSON-RPC id."
  @type id :: integer() | String.t()

  @typedoc "A decoded JSON-RPC message."
  @type message :: %{optional(String.t()) => term()}

  @type kind ::
          {:request, id(), method :: String.t(), params :: map()}
          | {:notification, method :: String.t()}
          | {:response, id()}
          | :batch
          | :invalid

  @doc "The MCP protocol version Butler announces to the backends."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc """
  Tells what a decoded JSON message is.

  A JSON array (which `Plug.Parsers` exposes as `%{"_json" => list}`) is a
  `:batch`, which the proxy does not support.
  """
  @spec classify(term()) :: kind()
  def classify(%{"_json" => list}) when is_list(list), do: :batch
  def classify(list) when is_list(list), do: :batch

  def classify(%{"jsonrpc" => @jsonrpc} = msg) do
    case msg do
      %{"method" => method} when is_binary(method) -> classify_call(msg, method)
      %{"method" => _other} -> :invalid
      %{"id" => id} when is_integer(id) or is_binary(id) -> classify_response(msg, id)
      _other -> :invalid
    end
  end

  def classify(_other), do: :invalid

  defp classify_call(msg, method) do
    with {:ok, params} <- params(msg) do
      case msg do
        %{"id" => id} when is_integer(id) or is_binary(id) -> {:request, id, method, params}
        %{"id" => _bad} -> :invalid
        _no_id -> {:notification, method}
      end
    end
  end

  defp classify_response(msg, id) do
    if Map.has_key?(msg, "result") or Map.has_key?(msg, "error"),
      do: {:response, id},
      else: :invalid
  end

  defp params(%{"params" => params}) when is_map(params), do: {:ok, params}
  defp params(%{"params" => _bad}), do: :invalid
  defp params(_no_params), do: {:ok, %{}}

  @doc "Encodes `message` as one newline-terminated JSON line."
  @spec encode_line(message()) :: binary()
  def encode_line(message), do: Jason.encode!(message) <> "\n"

  @doc "Decodes a line read from a backend. Only JSON objects are accepted."
  @spec decode_line(binary()) :: {:ok, message()} | :error
  def decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = message} -> {:ok, message}
      _other -> :error
    end
  end

  @doc "Returns `message` with its id replaced by `id`."
  @spec with_id(message(), id()) :: message()
  def with_id(message, id), do: Map.put(message, "id", id)

  @doc "A JSON-RPC result response."
  @spec result(id(), term()) :: message()
  def result(id, result), do: %{"jsonrpc" => @jsonrpc, "id" => id, "result" => result}

  @doc "A JSON-RPC error response."
  @spec error(id() | nil, integer(), String.t()) :: message()
  def error(id, code, message) do
    %{"jsonrpc" => @jsonrpc, "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  @doc "The error response for a body that is not valid JSON."
  @spec parse_error() :: message()
  def parse_error, do: error(nil, @parse_error, "Parse error")

  @doc "The error response for a message that is not a valid JSON-RPC request."
  @spec invalid_request(id() | nil) :: message()
  def invalid_request(id), do: error(id, @invalid_request, "Invalid Request")

  @doc "The error response for a failure inside the proxy or its backend."
  @spec internal_error(id() | nil, String.t()) :: message()
  def internal_error(id, message), do: error(id, @internal_error, message)

  @doc "The `initialize` request Butler sends to warm a backend up."
  @spec initialize_request(id(), String.t()) :: message()
  def initialize_request(id, client_name) do
    %{
      "jsonrpc" => @jsonrpc,
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => client_name, "version" => "1"}
      }
    }
  end

  @doc "The `notifications/initialized` notification completing the handshake."
  @spec initialized_notification() :: message()
  def initialized_notification do
    %{"jsonrpc" => @jsonrpc, "method" => "notifications/initialized"}
  end
end

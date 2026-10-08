defmodule Butler.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Butler.MCP.Protocol

  describe "classify/1" do
    test "a message with a method and an id is a request" do
      msg = %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list", "params" => %{"a" => 1}}
      assert Protocol.classify(msg) == {:request, 7, "tools/list", %{"a" => 1}}
    end

    test "string ids are supported and params default to an empty map" do
      msg = %{"jsonrpc" => "2.0", "id" => "abc", "method" => "ping"}
      assert Protocol.classify(msg) == {:request, "abc", "ping", %{}}
    end

    test "a message with a method and no id is a notification" do
      msg = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert Protocol.classify(msg) == {:notification, "notifications/initialized"}
    end

    test "a message with an id and a result or error is a response" do
      assert Protocol.classify(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}) ==
               {:response, 1}

      assert Protocol.classify(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => 1}}) ==
               {:response, 1}
    end

    test "a JSON array is a batch" do
      assert Protocol.classify(%{"_json" => [%{"id" => 1}]}) == :batch
      assert Protocol.classify([%{"id" => 1}]) == :batch
    end

    test "anything else is invalid" do
      assert Protocol.classify(%{}) == :invalid
      assert Protocol.classify(%{"jsonrpc" => "1.0", "id" => 1, "method" => "x"}) == :invalid
      assert Protocol.classify(%{"jsonrpc" => "2.0", "id" => 1.5, "method" => "x"}) == :invalid
      assert Protocol.classify(%{"jsonrpc" => "2.0", "id" => nil, "method" => "x"}) == :invalid
      assert Protocol.classify(%{"jsonrpc" => "2.0", "method" => 3}) == :invalid

      assert Protocol.classify(%{"jsonrpc" => "2.0", "id" => 1, "method" => "x", "params" => 3}) ==
               :invalid

      assert Protocol.classify("nope") == :invalid
    end
  end

  describe "wire format" do
    test "encode_line/1 produces one newline-terminated JSON line" do
      line = Protocol.encode_line(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      assert String.ends_with?(line, "\n")
      assert [_one] = String.split(line, "\n", trim: true)
      assert {:ok, %{"id" => 1}} = Protocol.decode_line(line)
    end

    test "decode_line/1 accepts only JSON objects" do
      assert {:ok, %{"a" => 1}} = Protocol.decode_line(~s({"a":1}\n))
      assert Protocol.decode_line("INFO starting up\n") == :error
      assert Protocol.decode_line("[1,2]") == :error
      assert Protocol.decode_line("") == :error
    end
  end

  describe "with_id/2" do
    test "replaces the id of a message" do
      msg = %{"jsonrpc" => "2.0", "id" => "client-id", "method" => "ping"}
      assert Protocol.with_id(msg, 42) == %{"jsonrpc" => "2.0", "id" => 42, "method" => "ping"}
    end
  end

  describe "builders" do
    test "error/3 builds a JSON-RPC error response" do
      assert Protocol.error(5, -32_603, "boom") == %{
               "jsonrpc" => "2.0",
               "id" => 5,
               "error" => %{"code" => -32_603, "message" => "boom"}
             }
    end

    test "error helpers use the standard codes" do
      assert %{"error" => %{"code" => -32_700}} = Protocol.parse_error()
      assert %{"error" => %{"code" => -32_600}, "id" => nil} = Protocol.invalid_request(nil)
      assert %{"error" => %{"code" => -32_603}, "id" => 2} = Protocol.internal_error(2, "x")
    end

    test "result/2 builds a JSON-RPC result response" do
      assert Protocol.result(3, %{"ok" => true}) ==
               %{"jsonrpc" => "2.0", "id" => 3, "result" => %{"ok" => true}}
    end

    test "initialize_request/2 and initialized_notification/0" do
      assert %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => params} =
               Protocol.initialize_request(1, "butler-test")

      assert params["clientInfo"]["name"] == "butler-test"
      assert is_binary(params["protocolVersion"])
      assert params["capabilities"] == %{}

      assert Protocol.initialized_notification() ==
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    end
  end
end

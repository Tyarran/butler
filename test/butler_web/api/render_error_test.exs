defmodule ButlerWeb.API.RenderErrorTest do
  use ButlerWeb.APICase, async: false

  alias ButlerWeb.API.JobParams
  alias ButlerWeb.API.RenderError
  alias ButlerWeb.API.Spec
  alias OpenApiSpex.Cast.Error

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/jobs", if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  # Request bodies that the OpenAPI schema refuses: the answer must be the one of
  # JobParams.validate/1, whatever the schema says.
  @invalid_bodies [
    {"a JSON array", ~s(["a"]), 400, "invalid_payload", nil},
    {"a JSON string", ~s("mine"), 400, "invalid_payload", nil},
    {"JSON null", "null", 400, "invalid_payload", nil},
    {"an empty object", "{}", 400, "invalid_payload", "kind"},
    {"an empty body", "", 400, "invalid_payload", "kind"},
    {"a non-string kind", ~s({"kind": 3}), 400, "invalid_payload", "kind"},
    {"an unknown kind", ~s({"kind": "nope"}), 422, "unknown_kind", "kind"},
    {"a UI-only kind", ~s({"kind": "repair"}), 403, "kind_not_allowed", "kind"},
    {"an unknown kind and a bad priority", ~s({"kind": "nope", "priority": "x"}), 422,
     "unknown_kind", "kind"},
    {"palace_path and a bad kind", ~s({"kind": "nope", "palace_path": "/x"}), 400,
     "invalid_payload", "palace_path"},
    {"an unknown key", ~s({"kind": "mine", "extra": 1}), 400, "invalid_payload", "extra"},
    {"an empty dedupe_key", ~s({"kind": "mine", "dedupe_key": ""}), 400, "invalid_payload",
     "dedupe_key"},
    {"a numeric dedupe_key", ~s({"kind": "mine", "dedupe_key": 5}), 400, "invalid_payload",
     "dedupe_key"},
    {"a float priority", ~s({"kind": "mine", "priority": 1.5}), 400, "invalid_payload",
     "priority"},
    {"a string priority", ~s({"kind": "mine", "priority": "high"}), 400, "invalid_payload",
     "priority"},
    {"a priority out of range", ~s({"kind": "mine", "priority": 1000001}), 400, "invalid_payload",
     "priority"},
    {"a payload that is not an object", ~s({"kind": "mine", "payload": [1]}), 400,
     "invalid_payload", "payload"},
    {"a relative source", ~s({"kind": "mine", "payload": {"source": "relative"}}), 400,
     "invalid_payload", "payload.source"}
  ]

  describe "the answer to an invalid body is the one of JobParams" do
    for {name, body, status, code, field} <- @invalid_bodies do
      test name, %{conn: conn} do
        conn = post_json(conn, unquote(body))
        error = json_response(conn, unquote(status))["error"]
        assert error["code"] == unquote(code)
        assert error["field"] == unquote(field)
        assert is_binary(error["message"])
      end
    end

    test "the message is the one of the validation chain", %{conn: conn} do
      conn = post_json(conn, %{kind: "mine", priority: "high"})
      assert %{"message" => "priority must be an integer"} = json_response(conn, 400)["error"]
    end
  end

  describe "valid bodies" do
    test "go through and keep their string-keyed params", %{conn: conn} do
      conn = post_json(conn, %{kind: "mine", payload: %{source: "/tmp/synthetic"}, priority: 2})
      assert %{"job" => %{"kind" => "mine"}} = json_response(conn, 202)
      assert conn.body_params["priority"] == 2
      assert %{"payload" => %{"source" => "/tmp/synthetic"}} = conn.body_params
    end

    test "are cast by the OpenAPI plug", %{conn: conn} do
      conn = post_json(conn, %{kind: "mine", payload: %{source: "/tmp/synthetic"}})
      assert %{open_api_spex: %{operation_id: "ButlerWeb.JobController.create"}} = conn.private
      assert %{open_api_spex: %{body_params: %{}}} = conn.private
    end
  end

  describe "content type" do
    test "a form-encoded body is refused: the API is JSON only", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post(~p"/api/v1/jobs", "kind=sync")

      assert %{"code" => "invalid_payload", "message" => message} =
               json_response(conn, 400)["error"]

      assert message =~ "application/json"
    end

    test "no content type: kind is required", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/jobs")
      assert %{"code" => "invalid_payload", "field" => "kind"} = json_response(conn, 400)["error"]
    end
  end

  describe "show and health are not cast" do
    test "include_payload stays lenient: only the literal true enables it", %{conn: conn} do
      created = conn |> post_json(%{kind: "mine", payload: %{source: "/tmp/synthetic"}})
      id = json_response(created, 202)["job"]["id"]

      for value <- ["1", "yes", "TRUE", "banana"] do
        shown = get(conn, ~p"/api/v1/jobs/#{id}?include_payload=#{value}")
        assert %{"job" => job} = json_response(shown, 200)
        refute Map.has_key?(job, "payload")
      end

      shown = get(conn, ~p"/api/v1/jobs/#{id}?include_payload=true")
      assert %{"job" => %{"payload" => _payload}} = json_response(shown, 200)
    end
  end

  describe "RenderError fallback" do
    test "a cast error the rules do not know is a 400 invalid_payload with the first error" do
      conn =
        Plug.Test.conn(:post, "/api/v1/jobs")
        |> Map.put(:body_params, %{"kind" => "mine", "payload" => %{"source" => "/tmp/synthetic"}})

      errors = [Error.new(%{path: [:priority], value: 1}, {:invalid_type, :integer})]
      conn = RenderError.call(conn, RenderError.init(errors))

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)

      assert %{"code" => "invalid_payload", "field" => "priority", "message" => message} =
               body["error"]

      assert is_binary(message)
    end
  end

  describe "drift: the schema is never stricter than the rules" do
    @bodies [
      %{"kind" => "mine", "payload" => %{"source" => "/tmp/synthetic"}},
      %{"kind" => "mine", "payload" => nil},
      %{"kind" => "mine", "payload" => []},
      %{"kind" => "mine", "payload" => ""},
      %{"kind" => "mine", "payload" => false},
      %{"kind" => "sweep", "payload" => %{"target" => "/tmp/synthetic"}},
      %{"kind" => "sync"},
      %{"kind" => "sync", "payload" => nil, "priority" => nil, "dedupe_key" => nil},
      %{"kind" => "mine", "dedupe_key" => String.duplicate("a", 200)},
      %{"kind" => "mine", "dedupe_key" => String.duplicate("é", 200)},
      %{"kind" => "mine", "dedupe_key" => String.duplicate("a", 201)},
      %{"kind" => "mine", "priority" => 1_000_000},
      %{"kind" => "mine", "priority" => -1_000_000},
      %{"kind" => "mine", "priority" => 1_000_001},
      %{"kind" => "mine", "priority" => 1.0},
      %{"kind" => "mine", "priority" => "3"},
      %{"kind" => "mine", "priority" => true},
      %{"kind" => "mine", "dedupe_key" => true},
      %{"kind" => "repair"},
      %{"kind" => "compress"},
      %{"kind" => "migrate-wings"},
      %{"kind" => "nope"},
      %{"kind" => nil},
      %{"kind" => ["mine"]},
      %{"kind" => "mine", "palace_path" => "/x"},
      %{"kind" => "mine", "other" => nil},
      %{"payload" => %{}},
      %{},
      %{"kind" => "mine", "payload" => [1]},
      %{"kind" => "diary_write", "payload" => %{"agent_name" => "a", "entry" => "synthetic"}},
      %{"kind" => "mcp_tool", "payload" => %{"name" => "mempalace_kg_add", "arguments" => %{}}}
    ]

    test "whenever the schema refuses a body, JobParams refuses it too" do
      spec = Spec.spec()
      schema = spec.components.schemas["JobRequest"]

      for body <- @bodies do
        case {OpenApiSpex.cast_value(body, schema, spec), JobParams.validate(body)} do
          {{:error, _errors}, {:ok, _attrs}} ->
            flunk("the schema is stricter than the rules for " <> inspect(body))

          _consistent ->
            :ok
        end
      end
    end

    test "whenever the rules accept a body, the schema accepts it too" do
      spec = Spec.spec()
      schema = spec.components.schemas["JobRequest"]

      for body <- @bodies, {:ok, _attrs} <- [JobParams.validate(body)] do
        assert {:ok, _cast} = OpenApiSpex.cast_value(body, schema, spec)
      end
    end
  end
end

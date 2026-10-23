defmodule ButlerWeb.API.SpecTest do
  use ButlerWeb.APICase, async: false

  import OpenApiSpex.TestAssertions

  alias Butler.Jobs.Kinds
  alias ButlerWeb.API.JobParams
  alias ButlerWeb.API.Spec

  @create "ButlerWeb.JobController.create"
  @show "ButlerWeb.JobController.show"
  @health "ButlerWeb.HealthController.show"

  defp spec, do: Spec.spec()

  defp create(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/jobs", Jason.encode!(body))
  end

  describe "the document" do
    test "describes the three /api/v1 operations and nothing else" do
      assert %{paths: paths} = spec()

      assert paths |> Map.keys() |> Enum.sort() == [
               "/api/v1/health",
               "/api/v1/jobs",
               "/api/v1/jobs/{id}"
             ]

      assert %{post: %{operationId: @create}} = paths["/api/v1/jobs"]
      assert %{get: %{operationId: @show}} = paths["/api/v1/jobs/{id}"]
      assert %{get: %{operationId: @health}} = paths["/api/v1/health"]
    end

    test "declares the Bearer security scheme for the whole API" do
      assert %{components: %{securitySchemes: %{"bearerAuth" => scheme}}} = spec()
      assert %{type: "http", scheme: "bearer"} = scheme
      assert spec().security == [%{"bearerAuth" => []}]
    end

    test "the version comes from the application and the server is relative" do
      assert spec().info.version == to_string(Application.spec(:butler, :vsn))
      assert [%{url: "/"}] = spec().servers
    end

    test "the kind enum is Kinds.api_kinds/0" do
      assert %{properties: %{kind: kind}} = spec().components.schemas["JobRequest"]
      assert kind.enum == Kinds.api_kinds()
    end

    test "the request only accepts the known top-level keys" do
      schema = spec().components.schemas["JobRequest"]
      assert schema.additionalProperties == false
      assert schema.required == [:kind]

      assert schema.properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() ==
               Enum.sort(JobParams.body_keys())
    end

    test "every operation declares its error responses" do
      %{paths: paths} = spec()

      responses = fn path, verb ->
        paths |> Map.fetch!(path) |> Map.fetch!(verb) |> Map.fetch!(:responses) |> Map.keys()
      end

      assert responses.("/api/v1/jobs", :post) |> Enum.sort() ==
               [202, 400, 401, 403, 413, 422, 503]

      assert responses.("/api/v1/jobs/{id}", :get) |> Enum.sort() == [200, 401, 403, 404, 503]
      assert responses.("/api/v1/health", :get) |> Enum.sort() == [200, 401, 403, 503]
    end

    test "the error codes are the documented ones" do
      assert %{properties: %{error: %{properties: %{code: code}}}} =
               spec().components.schemas["ErrorResponse"]

      assert Enum.sort(code.enum) ==
               Enum.sort(
                 ~w(invalid_payload unauthorized forbidden kind_not_allowed not_found too_large unknown_kind queue_unavailable)
               )
    end

    test "the document encodes to JSON" do
      assert %{"openapi" => "3." <> _rest} = spec() |> Jason.encode!() |> Jason.decode!()
    end
  end

  describe "real responses conform to the declared schemas" do
    test "202 on create and 200 on show (without and with payload)", %{conn: conn} do
      created =
        create(conn, %{kind: "mine", payload: %{source: "/tmp/synthetic"}, dedupe_key: "k"})

      assert %{"job" => %{"id" => id}} = json_response(created, 202)
      assert_operation_response(created, @create)

      shown = get(conn, ~p"/api/v1/jobs/#{id}")
      assert json_response(shown, 200)
      assert_operation_response(shown, @show)

      with_payload = get(conn, ~p"/api/v1/jobs/#{id}?include_payload=true")
      assert %{"job" => %{"payload" => %{}}} = json_response(with_payload, 200)
      assert_operation_response(with_payload, @show)
    end

    test "the response bodies also match the named schemas", %{conn: conn} do
      created =
        conn
        |> create(%{kind: "mine", payload: %{source: "/tmp/synthetic"}})
        |> json_response(202)

      assert_schema(created, "JobCreatedResponse", spec())

      id = created["job"]["id"]

      assert_schema(
        conn |> get(~p"/api/v1/jobs/#{id}") |> json_response(200),
        "JobResponse",
        spec()
      )
    end

    test "404 on an unknown job", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/jobs/nope")
      assert json_response(conn, 404)
      assert_operation_response(conn, @show)
    end

    test "400, 403 and 422 on create", %{conn: conn} do
      for {body, status} <- [
            {%{kind: "mine", payload: %{source: "relative"}}, 400},
            {%{kind: "repair"}, 403},
            {%{kind: "nope"}, 422}
          ] do
        conn = create(conn, body)
        assert json_response(conn, status)
        assert_operation_response(conn, @create)
      end
    end

    test "health answers with the declared shape (503: no worker in tests)", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert %{"ok" => false, "counts" => %{}} = json_response(conn, 503)
      assert_operation_response(conn, @health)
    end

    test "401 and 403 use ErrorResponse", %{conn: conn} do
      unauthorized = conn |> delete_req_header("authorization") |> get(~p"/api/v1/health")
      assert_schema(json_response(unauthorized, 401), "ErrorResponse", spec())

      forbidden = get(%{conn | host: "evil.example"}, ~p"/api/v1/health")
      assert_schema(json_response(forbidden, 403), "ErrorResponse", spec())
    end
  end
end

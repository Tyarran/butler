defmodule ButlerWeb.API.OpenAPIRouteTest do
  use ButlerWeb.ConnCase, async: true

  defp local(conn), do: %{conn | host: "localhost"}

  test "GET /openapi serves the document without a token", %{conn: conn} do
    conn = conn |> local() |> get(~p"/openapi")

    assert ["application/json" <> _charset] = get_resp_header(conn, "content-type")
    assert %{"openapi" => "3." <> _rest, "paths" => paths} = json_response(conn, 200)

    assert paths |> Map.keys() |> Enum.sort() ==
             ["/api/v1/health", "/api/v1/jobs", "/api/v1/jobs/{id}"]
  end

  test "the document declares the Bearer scheme and applies it", %{conn: conn} do
    doc = conn |> local() |> get(~p"/openapi") |> json_response(200)

    assert %{"bearerAuth" => %{"type" => "http", "scheme" => "bearer"}} =
             doc["components"]["securitySchemes"]

    assert doc["security"] == [%{"bearerAuth" => []}]
  end

  test "the document does not list the doc routes themselves", %{conn: conn} do
    doc = conn |> local() |> get(~p"/openapi") |> json_response(200)
    refute Map.has_key?(doc["paths"], "/openapi")
    refute Map.has_key?(doc["paths"], "/swaggerui")
  end

  test "a non-loopback peer, Host or Origin is a 403", %{conn: conn} do
    assert %{"error" => %{"code" => "forbidden"}} =
             %{conn | remote_ip: {10, 0, 0, 5}, host: "localhost"}
             |> get(~p"/openapi")
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             %{conn | host: "evil.example"} |> get(~p"/openapi") |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             conn
             |> local()
             |> put_req_header("origin", "https://evil.example")
             |> get(~p"/openapi")
             |> json_response(403)
  end

  test "the API itself still needs the token", %{conn: conn} do
    conn = conn |> local() |> get(~p"/api/v1/health")
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end
end

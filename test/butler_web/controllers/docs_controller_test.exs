defmodule ButlerWeb.DocsControllerTest do
  use ButlerWeb.ConnCase, async: true

  defp local(conn), do: %{conn | host: "localhost"}

  defp page(conn), do: conn |> local() |> get(~p"/swaggerui")

  test "GET /swaggerui renders the Swagger UI mount point without a token", %{conn: conn} do
    conn = page(conn)
    html = html_response(conn, 200)

    document = LazyHTML.from_document(html)

    assert [_one] =
             LazyHTML.to_tree(LazyHTML.query(document, "#swagger-ui[data-spec-url='/openapi']"))
  end

  test "the page loads its own bundle and style, nothing from the network", %{conn: conn} do
    html = conn |> page() |> html_response(200)
    document = LazyHTML.from_document(html)

    scripts = document |> LazyHTML.query("script[src]") |> LazyHTML.attribute("src")
    styles = document |> LazyHTML.query("link[rel=stylesheet]") |> LazyHTML.attribute("href")

    assert Enum.any?(scripts, &String.starts_with?(&1, "/assets/js/swagger.js"))
    assert Enum.any?(styles, &String.starts_with?(&1, "/assets/js/swagger.css"))

    for url <- scripts ++ styles do
      assert String.starts_with?(url, "/"), "not same-origin: #{url}"
      refute url =~ ~r{^(https?:)?//}
    end

    refute html =~ "unpkg"
    refute html =~ "cdn"
    refute html =~ ~r{(src|href)="https?://}
  end

  test "the page needs no inline script and does not load the dashboard bundle", %{conn: conn} do
    html = conn |> page() |> html_response(200)
    document = LazyHTML.from_document(html)

    assert [] = LazyHTML.to_tree(LazyHTML.query(document, "script:not([src])"))
    refute html =~ "/assets/js/app.js"
  end

  test "the CSP is the one of the browser pipeline", %{conn: conn} do
    docs = page(conn)
    dashboard = conn |> local() |> get(~p"/palace")

    assert [csp] = get_resp_header(docs, "content-security-policy")
    assert get_resp_header(dashboard, "content-security-policy") == [csp]
  end

  test "a non-loopback peer, Host or Origin is a 403", %{conn: conn} do
    assert %{"error" => %{"code" => "forbidden"}} =
             %{conn | remote_ip: {10, 0, 0, 5}}
             |> local()
             |> get(~p"/swaggerui")
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             %{conn | host: "evil.example"} |> get(~p"/swaggerui") |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             conn
             |> local()
             |> put_req_header("origin", "https://evil.example")
             |> get(~p"/swaggerui")
             |> json_response(403)
  end
end

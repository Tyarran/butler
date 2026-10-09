defmodule ButlerWeb.JobControllerTest do
  # Global names (queue) and application env (state dir): no concurrency.
  use ButlerWeb.ConnCase, async: false

  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: tmp} do
    previous = Application.fetch_env(:butler, :state_dir)
    Application.put_env(:butler, :state_dir, Path.join(tmp, "state"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:butler, :state_dir, value)
        :error -> Application.delete_env(:butler, :state_dir)
      end
    end)

    start_supervised!({Queue, name: Queue, path: Path.join([tmp, "state", "queue.sqlite3"])})
    {:ok, token} = Butler.Token.ensure()

    conn =
      %{conn | host: "localhost"}
      |> put_req_header("authorization", "Bearer " <> token)

    {:ok, conn: conn, token: token}
  end

  defp submit(conn, body), do: post(conn, ~p"/api/v1/jobs", body)

  defp raw(conn, body) do
    conn |> put_req_header("content-type", "application/json") |> post(~p"/api/v1/jobs", body)
  end

  defp error_of(conn, status), do: json_response(conn, status)["error"]

  describe "access control" do
    test "no token: 401", %{conn: conn} do
      conn = conn |> delete_req_header("authorization") |> submit(%{kind: "mine"})
      assert %{"code" => "unauthorized"} = error_of(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "wrong token or scheme: 401", %{conn: conn} do
      bad = conn |> put_req_header("authorization", "Bearer nope") |> submit(%{kind: "mine"})
      assert %{"code" => "unauthorized"} = error_of(bad, 401)

      basic = conn |> put_req_header("authorization", "Basic abc") |> get(~p"/api/v1/health")
      assert %{"code" => "unauthorized"} = error_of(basic, 401)
    end

    test "foreign Host or Origin: 403", %{conn: conn} do
      host = submit(%{conn | host: "evil.example"}, %{kind: "mine"})
      assert %{"code" => "forbidden"} = error_of(host, 403)

      origin = conn |> put_req_header("origin", "https://evil.example") |> get(~p"/api/v1/health")
      assert %{"code" => "forbidden"} = error_of(origin, 403)
    end

    test "non-loopback peer: 403", %{conn: conn} do
      conn = submit(%{conn | remote_ip: {10, 0, 0, 5}}, %{kind: "mine"})
      assert %{"code" => "forbidden"} = error_of(conn, 403)
    end

    test "body over 1 MB: 413", %{conn: conn} do
      big = String.duplicate("a", 1_100_000)

      body = Jason.encode!(%{kind: "diary_write", payload: %{agent_name: "a", entry: big}})
      assert_error_sent 413, fn -> raw(conn, body) end
    end
  end

  describe "POST /api/v1/jobs" do
    test "enqueues a mine job (202)", %{conn: conn} do
      conn =
        submit(conn, %{
          kind: "mine",
          payload: %{source: "/tmp/sessions", mode: "convos", wing: "w", limit: 5},
          dedupe_key: "daily"
        })

      assert %{"job" => job} = json_response(conn, 202)
      assert %{"kind" => "mine", "state" => "queued", "dedupe_key" => "daily"} = job
      assert job["deduplicated"] == false
      assert is_binary(job["id"]) and is_binary(job["created_at"])
      refute Map.has_key?(job, "payload")
    end

    test "a dedupe hit answers 202 with the existing job", %{conn: conn} do
      body = %{kind: "sweep", payload: %{target: "/tmp/s"}, dedupe_key: "k"}
      first = conn |> submit(body) |> json_response(202)
      second = conn |> submit(body) |> json_response(202)

      assert first["job"]["deduplicated"] == false
      assert second["job"]["deduplicated"] == true
      assert second["job"]["id"] == first["job"]["id"]
    end

    test "unknown kind: 422", %{conn: conn} do
      assert %{"code" => "unknown_kind"} = conn |> submit(%{kind: "nope"}) |> error_of(422)
    end

    test "missing kind: 400", %{conn: conn} do
      assert %{"code" => "invalid_payload", "field" => "kind"} =
               conn |> submit(%{payload: %{}}) |> error_of(400)
    end

    for kind <- ~w(repair compress migrate-wings) do
      test "#{kind} is UI-only: 403 kind_not_allowed", %{conn: conn} do
        conn = submit(conn, %{kind: unquote(kind), payload: %{}})
        assert %{"code" => "kind_not_allowed"} = error_of(conn, 403)
        assert {:ok, []} = Queue.list(Queue)
      end
    end

    test "payload errors name the field", %{conn: conn} do
      relative = submit(conn, %{kind: "mine", payload: %{source: "relative"}})
      assert %{"code" => "invalid_payload", "field" => "payload.source"} = error_of(relative, 400)

      dash = submit(conn, %{kind: "sweep", payload: %{target: "-rf"}})
      assert %{"field" => "payload.target"} = error_of(dash, 400)

      extra = submit(conn, %{kind: "mine", payload: %{source: "/a", bogus: 1}})
      assert %{"field" => "payload.bogus"} = error_of(extra, 400)

      mode = submit(conn, %{kind: "mine", payload: %{source: "/a", mode: "weird"}})
      assert %{"field" => "payload.mode"} = error_of(mode, 400)

      limit = submit(conn, %{kind: "mine", payload: %{source: "/a", limit: 0}})
      assert %{"field" => "payload.limit"} = error_of(limit, 400)

      shape = submit(conn, %{kind: "mine", payload: "text"})
      assert %{"field" => "payload"} = error_of(shape, 400)

      assert {:ok, []} = Queue.list(Queue)
    end

    test "a client palace_path is refused", %{conn: conn} do
      top = submit(conn, %{kind: "mine", palace_path: "/x", payload: %{source: "/a"}})
      assert %{"field" => "palace_path"} = error_of(top, 400)

      inner = submit(conn, %{kind: "mine", payload: %{source: "/a", palace_path: "/x"}})
      assert %{"field" => "payload.palace_path"} = error_of(inner, 400)
    end

    test "dedupe_key and priority are validated", %{conn: conn} do
      long = submit(conn, %{kind: "sync", dedupe_key: String.duplicate("a", 201)})
      assert %{"field" => "dedupe_key"} = error_of(long, 400)

      number = submit(conn, %{kind: "sync", dedupe_key: 3})
      assert %{"field" => "dedupe_key"} = error_of(number, 400)

      priority = submit(conn, %{kind: "sync", priority: "high"})
      assert %{"field" => "priority"} = error_of(priority, 400)
    end

    test "a non-object body: 400", %{conn: conn} do
      conn = raw(conn, ~s(["a"]))
      assert %{"code" => "invalid_payload"} = error_of(conn, 400)
    end

    test "sync defaults to a dry run; apply needs an explicit false and a scope", %{conn: conn} do
      id = conn |> submit(%{kind: "sync"}) |> json_response(202) |> get_in(["job", "id"])
      {:ok, job} = Queue.get(Queue, id)
      assert job.payload["dry_run"] == true
      assert {:ok, argv} = Kinds.argv("sync", job.payload, palace: "/p")
      assert "--dry-run" in argv and "--apply" not in argv

      unscoped = submit(conn, %{kind: "sync", payload: %{dry_run: false}})
      assert %{"field" => "payload.dry_run"} = error_of(unscoped, 400)

      apply_id =
        conn
        |> submit(%{kind: "sync", payload: %{dry_run: false, wing: "w"}})
        |> json_response(202)
        |> get_in(["job", "id"])

      {:ok, applied} = Queue.get(Queue, apply_id)
      assert {:ok, argv} = Kinds.argv("sync", applied.payload, palace: "/p")
      assert "--apply" in argv
    end

    test "diary_write is validated and enqueued", %{conn: conn} do
      ok = submit(conn, %{kind: "diary_write", payload: %{agent_name: "a", entry: "synthetic"}})
      assert %{"job" => %{"kind" => "diary_write"}} = json_response(ok, 202)

      missing = submit(conn, %{kind: "diary_write", payload: %{agent_name: "a"}})
      assert %{"field" => "payload.entry"} = error_of(missing, 400)
    end

    test "mcp_tool only accepts the write allowlist", %{conn: conn} do
      for name <- ["mempalace_checkpoint", "mempalace_kg_supersede", "mempalace_kg_add"] do
        conn = submit(conn, %{kind: "mcp_tool", payload: %{name: name, arguments: %{a: 1}}})
        assert %{"job" => %{"kind" => "mcp_tool"}} = json_response(conn, 202)
      end

      for name <- ["mempalace_search", "mempalace_mine", "nope", 42] do
        conn = submit(conn, %{kind: "mcp_tool", payload: %{name: name, arguments: %{}}})
        assert %{"field" => "payload.name"} = error_of(conn, 400)
      end

      bad_args =
        submit(conn, %{kind: "mcp_tool", payload: %{name: "mempalace_kg_add", arguments: 1}})

      assert %{"field" => "payload.arguments"} = error_of(bad_args, 400)
    end
  end

  describe "GET /api/v1/jobs/:id" do
    test "hides the payload unless include_payload=true", %{conn: conn} do
      id =
        conn
        |> submit(%{kind: "diary_write", payload: %{agent_name: "a", entry: "synthetic"}})
        |> json_response(202)
        |> get_in(["job", "id"])

      job = conn |> get(~p"/api/v1/jobs/#{id}") |> json_response(200) |> Map.fetch!("job")
      assert %{"id" => ^id, "state" => "queued", "attempts" => 0} = job
      refute Map.has_key?(job, "payload")

      with_payload =
        conn
        |> get(~p"/api/v1/jobs/#{id}?include_payload=true")
        |> json_response(200)
        |> get_in(["job", "payload"])

      assert with_payload["entry"] == "synthetic"
    end

    test "unknown id: 404", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/jobs/missing")
      assert %{"code" => "not_found"} = error_of(conn, 404)
    end

    test "requires the token", %{conn: conn} do
      conn = conn |> delete_req_header("authorization") |> get(~p"/api/v1/jobs/x")
      assert %{"code" => "unauthorized"} = error_of(conn, 401)
    end
  end

  describe "GET /api/v1/health" do
    test "reports counts and the maintenance flag; 503 without the worker", %{conn: conn} do
      submit(conn, %{kind: "sync"})
      conn = get(conn, ~p"/api/v1/health")

      # The worker is dormant in tests (`start_jobs: false`).
      assert %{"ok" => false, "worker" => "unavailable", "maintenance" => false} =
               body = json_response(conn, 503)

      assert body["counts"]["queued"] == 1
    end

    test "ok with a running idle worker", %{conn: conn} do
      start_supervised!({Worker, queue: Queue, legacy_running?: fn -> false end})
      _ = Worker.status()

      body = conn |> get(~p"/api/v1/health") |> json_response(200)

      assert %{"ok" => true, "worker" => "idle", "active_job_id" => nil, "maintenance" => false} =
               body

      assert %{"queued" => 0} = body["counts"]
    end
  end
end

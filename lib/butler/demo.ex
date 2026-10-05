defmodule Butler.Demo do
  @moduledoc """
  Builds a demo MemPalace home filled with **synthetic** data, to try or
  screenshot Butler without a real palace (see `mix butler.demo`).

  The demo has a fake palace (`/demo/palace`, which never exists on disk) and
  a queue database with the exact daemon schema, jobs in every state, and an
  `endpoint.json` pointing to the current VM so that the daemon looks
  *running*.
  """

  alias Butler.Daemon.Locator
  alias Exqlite.Sqlite3

  @palace "/demo/palace"
  @queue_file "queue.sqlite3"
  @endpoint_file "endpoint.json"

  # Mirrors the daemon queue schema (see test/support/queue_fixture.ex, and the
  # demo test which checks both are identical).
  @schema [
    """
    CREATE TABLE jobs (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      state TEXT NOT NULL,
      priority INTEGER NOT NULL DEFAULT 0,
      dedupe_key TEXT,
      created_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      result_json TEXT,
      error_json TEXT,
      attempts INTEGER NOT NULL DEFAULT 0
    )
    """,
    "CREATE INDEX idx_jobs_state ON jobs(state, priority)",
    "CREATE INDEX idx_jobs_dedupe ON jobs(dedupe_key, state)",
    """
    CREATE UNIQUE INDEX idx_jobs_dedupe_active ON jobs(dedupe_key)
    WHERE state IN ('queued', 'running')
    """
  ]

  @columns ~w(id kind payload_json state priority dedupe_key created_at started_at
              finished_at result_json error_json attempts)a
  @insert_sql "INSERT INTO jobs (#{Enum.join(@columns, ", ")}) VALUES (#{Enum.map_join(@columns, ", ", fn _ -> "?" end)})"

  @projects ~w(atlas borealis cobalt delta ember fjord garnet harbor)
  @mine_seconds [250, 310, 280, 330, 295, 270, 305, 320]
  @hour 3_600

  @type t :: %{home: Path.t(), palace: Path.t(), queue: Path.t(), daemon_dir: Path.t()}

  @doc "The fake palace path used by the demo."
  @spec palace() :: Path.t()
  def palace, do: @palace

  @doc """
  Builds the demo under `home` (any previous demo there is replaced) and
  returns its paths.
  """
  @spec build!(Path.t()) :: t()
  def build!(home) do
    home = Path.expand(home)
    daemon_dir = Path.join([home, "daemon", Locator.palace_key(@palace)])
    queue = Path.join(daemon_dir, @queue_file)

    File.rm_rf!(Path.join(home, "daemon"))
    File.mkdir_p!(daemon_dir)
    create_queue!(queue, jobs(DateTime.utc_now()))
    write_endpoint!(daemon_dir)

    %{home: home, palace: @palace, queue: queue, daemon_dir: daemon_dir}
  end

  @doc "Writes the demo daemon's `endpoint.json` (the daemon looks running)."
  @spec write_endpoint!(Path.t()) :: :ok
  def write_endpoint!(daemon_dir) do
    endpoint = %{
      "host" => "127.0.0.1",
      "port" => 7878,
      "pid" => String.to_integer(System.pid()),
      "palace_path" => @palace,
      "started_at" => iso(DateTime.add(DateTime.utc_now(), -2 * @hour, :second))
    }

    File.write!(Path.join(daemon_dir, @endpoint_file), Jason.encode!(endpoint))
  end

  @doc "Removes the demo daemon's `endpoint.json` (the daemon looks stopped)."
  @spec remove_endpoint!(Path.t()) :: :ok
  def remove_endpoint!(daemon_dir) do
    _ = File.rm(Path.join(daemon_dir, @endpoint_file))
    :ok
  end

  # Jobs

  defp jobs(now) do
    mines = Enum.zip(@projects, @mine_seconds) |> Enum.with_index(1)

    finished_mines =
      for {{project, seconds}, n} <- mines do
        started = DateTime.add(now, -(n * @hour + 600), :second)

        job(n,
          kind: "mine",
          state: "succeeded",
          payload: mine_payload(project),
          created_at: DateTime.add(started, -5, :second),
          started_at: started,
          finished_at: DateTime.add(started, seconds, :second),
          attempts: 1,
          result: %{
            "success" => true,
            "kind" => "mine",
            "mode" => "projects",
            "dry_run" => false,
            "exit_code" => 0,
            "stdout" => mine_report(project)
          }
        )
      end

    finished_mines ++
      [
        job(20,
          kind: "mine",
          state: "running",
          payload: mine_payload("ivory"),
          created_at: DateTime.add(now, -250, :second),
          started_at: DateTime.add(now, -240, :second),
          attempts: 1
        ),
        job(21,
          kind: "sweep",
          state: "queued",
          payload: %{"palace_path" => @palace, "target" => "/demo/transcripts"},
          created_at: DateTime.add(now, -30, :second)
        ),
        job(22,
          kind: "mine",
          state: "queued",
          payload: mine_payload("jade"),
          created_at: DateTime.add(now, -20, :second)
        ),
        job(23,
          kind: "mine",
          state: "failed",
          payload: mine_payload("missing"),
          created_at: DateTime.add(now, -3 * @hour, :second),
          started_at: DateTime.add(now, -3 * @hour + 2, :second),
          finished_at: DateTime.add(now, -3 * @hour + 3, :second),
          attempts: 1,
          error: %{
            "error_class" => "FileNotFoundError",
            "message" => "Source directory not found: /demo/projects/missing"
          }
        ),
        job(24,
          kind: "mine",
          state: "cancelled",
          payload: mine_payload("kappa"),
          created_at: DateTime.add(now, -5 * @hour, :second),
          started_at: DateTime.add(now, -5 * @hour + 4, :second),
          finished_at: DateTime.add(now, -5 * @hour + 120, :second),
          attempts: 1,
          error: %{"message" => "cancelled by daemon shutdown"}
        ),
        job(25,
          kind: "sweep",
          state: "succeeded",
          payload: %{"palace_path" => @palace, "target" => "/demo/transcripts"},
          created_at: DateTime.add(now, -6 * @hour, :second),
          started_at: DateTime.add(now, -6 * @hour + 1, :second),
          finished_at: DateTime.add(now, -6 * @hour + 9, :second),
          attempts: 1,
          result: %{
            "success" => true,
            "kind" => "sweep",
            "exit_code" => 0,
            "stdout" => " Swept 3/3 files from /demo/transcripts: +12 new, 0 already present\n"
          }
        ),
        job(26,
          kind: "sync",
          state: "succeeded",
          payload: %{
            "dir" => nil,
            "dry_run" => true,
            "palace_path" => @palace,
            "root" => [],
            "wing" => nil
          },
          created_at: DateTime.add(now, -7 * @hour, :second),
          started_at: DateTime.add(now, -7 * @hour + 1, :second),
          finished_at: DateTime.add(now, -7 * @hour + 4, :second),
          attempts: 1,
          result: %{
            "success" => true,
            "exit_code" => 0,
            "stdout" => "\n  Dry run: nothing to delete.\n"
          }
        )
      ] ++ tool_jobs(now)
  end

  defp tool_jobs(now) do
    ok =
      for n <- 1..5 do
        started = DateTime.add(now, -(n * 600), :second)

        job(100 + n,
          kind: "mcp_tool",
          state: "succeeded",
          payload: %{"name" => "demo_status", "arguments" => %{}, "palace_path" => @palace},
          created_at: started,
          started_at: started,
          finished_at: DateTime.add(started, 2, :second),
          attempts: 1,
          result: %{"success" => true}
        )
      end

    failed =
      job(110,
        kind: "mcp_tool",
        state: "failed",
        payload: %{
          "name" => "demo_missing_tool",
          "arguments" => %{"demo" => true},
          "palace_path" => @palace
        },
        created_at: DateTime.add(now, -900, :second),
        started_at: DateTime.add(now, -899, :second),
        finished_at: DateTime.add(now, -898, :second),
        attempts: 1,
        error: %{"error_class" => "TypeError", "message" => "Unknown tool: demo_missing_tool"}
      )

    ok ++ [failed]
  end

  defp mine_payload(project) do
    %{
      "agent" => "demo",
      "dry_run" => false,
      "extract" => "exchange",
      "include_ignored" => [],
      "limit" => 0,
      "max_chunks_per_file" => nil,
      "mode" => "projects",
      "no_gitignore" => false,
      "palace_path" => @palace,
      "redetect_origin" => false,
      "source" => "/demo/projects/#{project}",
      "wing" => project
    }
  end

  defp mine_report(project) do
    """

    =======================================================
      MemPalace Mine
    =======================================================
      Wing:    #{project}
      Rooms:   general, docs
      Files:   112
      Palace:  #{@palace}
    =======================================================
      + [1/112] README.md
      + [2/112] docs/guide.md
      + [63/112] src/main.ex
      + [112/112] notes/changelog.md

      Hallways: 2 new   Tunnels: 1 new
    Done.
    """
  end

  defp job(n, attrs) do
    base = %{
      id: id(n),
      kind: "mine",
      state: "queued",
      priority: 0,
      dedupe_key: nil,
      started_at: nil,
      finished_at: nil,
      result: nil,
      error: nil,
      attempts: 0
    }

    Map.merge(base, Map.new(attrs))
  end

  # Deterministic 32-hex ids, like the daemon's uuid4 hex.
  defp id(n), do: Base.encode16(:crypto.hash(:md5, "butler-demo-#{n}"), case: :lower)

  # Database

  defp create_queue!(path, jobs) do
    {:ok, db} = Sqlite3.open(path, mode: [:readwrite, :create])

    try do
      :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
      Enum.each(@schema, fn sql -> :ok = Sqlite3.execute(db, sql) end)
      Enum.each(jobs, &insert!(db, &1))
    after
      Sqlite3.close(db)
    end
  end

  defp insert!(db, job) do
    values = [
      job.id,
      job.kind,
      Jason.encode!(job.payload),
      job.state,
      job.priority,
      job.dedupe_key,
      iso(job.created_at),
      iso(job[:started_at]),
      iso(job[:finished_at]),
      json(job.result),
      json(job.error),
      job.attempts
    ]

    {:ok, stmt} = Sqlite3.prepare(db, @insert_sql)
    :ok = Sqlite3.bind(stmt, values)
    :done = Sqlite3.step(db, stmt)
    :ok = Sqlite3.release(db, stmt)
  end

  defp json(nil), do: nil
  defp json(value), do: Jason.encode!(value)

  defp iso(nil), do: nil

  defp iso(%DateTime{} = datetime),
    do: datetime |> DateTime.to_iso8601() |> String.replace("Z", "+00:00")
end

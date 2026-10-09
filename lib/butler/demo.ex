defmodule Butler.Demo do
  @moduledoc """
  Builds a demo Butler state directory filled with **synthetic** data, to try
  or screenshot Butler without a real palace (see `mix butler.demo`).

  Only **terminal** (succeeded, failed, cancelled) and **queued** rows are
  seeded, never a `running` one: a running row has no live worker behind it,
  so the engine would have to recover it at startup.

  The demo has a fake palace (`/demo/palace`, which never exists on disk) and
  a queue database in Butler's own schema (created by
  `Butler.Jobs.Store.open/1`, so with the right file modes) holding
  queued and finished jobs. The demo home has no Python daemon, so the worker is not
  blocked; the CLI is `Butler.CLI.Demo`, which runs nothing.
  """

  alias Butler.Jobs.Store
  alias Exqlite.Sqlite3

  @palace "/demo/palace"
  @state_subdir "state"

  @columns ~w(id kind payload_json state priority dedupe_key created_at started_at
              finished_at result_json error_json attempts)a
  @insert_sql "INSERT INTO jobs (#{Enum.join(@columns, ", ")}) VALUES (#{Enum.map_join(@columns, ", ", fn _ -> "?" end)})"

  @projects ~w(atlas borealis cobalt delta ember fjord garnet harbor)
  @mine_seconds [250, 310, 280, 330, 295, 270, 305, 320]
  @hour 3_600

  @type t :: %{home: Path.t(), palace: Path.t(), state_dir: Path.t(), queue: Path.t()}

  @doc "The fake palace path used by the demo."
  @spec palace() :: Path.t()
  def palace, do: @palace

  @doc """
  Builds the demo under `home` (any previous demo there is replaced) and
  returns its paths. The Butler state directory is `<home>/state`.
  """
  @spec build!(Path.t()) :: t()
  def build!(home) do
    home = Path.expand(home)
    state_dir = Path.join(home, @state_subdir)
    queue = Path.join(state_dir, "queue.sqlite3")

    File.rm_rf!(state_dir)
    create_queue!(queue, jobs(DateTime.utc_now()))

    %{home: home, palace: @palace, state_dir: state_dir, queue: queue}
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
          result: %{"exit_status" => 0, "output_tail" => mine_report(project)}
        )
      end

    finished_mines ++
      [
        job(21,
          kind: "sweep",
          state: "queued",
          payload: %{"target" => "/demo/transcripts"},
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
            "class" => "CommandFailed",
            "message" => "mempalace exited with status 1",
            "exit_status" => 1,
            "output_tail" => "Source directory not found: /demo/projects/missing\n"
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
          error: %{"class" => "Cancelled", "message" => "cancelled from the dashboard"}
        ),
        job(25,
          kind: "sweep",
          state: "succeeded",
          payload: %{"target" => "/demo/transcripts"},
          created_at: DateTime.add(now, -6 * @hour, :second),
          started_at: DateTime.add(now, -6 * @hour + 1, :second),
          finished_at: DateTime.add(now, -6 * @hour + 9, :second),
          attempts: 1,
          result: %{
            "exit_status" => 0,
            "output_tail" =>
              " Swept 3/3 files from /demo/transcripts: +12 new, 0 already present\n"
          }
        ),
        job(26,
          kind: "sync",
          state: "succeeded",
          payload: %{"dry_run" => true},
          created_at: DateTime.add(now, -7 * @hour, :second),
          started_at: DateTime.add(now, -7 * @hour + 1, :second),
          finished_at: DateTime.add(now, -7 * @hour + 4, :second),
          attempts: 1,
          result: %{"exit_status" => 0, "output_tail" => "\n  Dry run: nothing to delete.\n"}
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
          payload: %{"name" => "mempalace_kg_add", "arguments" => %{"demo" => n}},
          created_at: started,
          started_at: started,
          finished_at: DateTime.add(started, 2, :second),
          attempts: 1,
          result: %{"tool" => "mempalace_kg_add", "result" => %{"success" => true}}
        )
      end

    failed =
      job(110,
        kind: "diary_write",
        state: "failed",
        payload: %{"agent_name" => "demo-agent", "entry" => "Synthetic demo entry."},
        created_at: DateTime.add(now, -900, :second),
        started_at: DateTime.add(now, -899, :second),
        finished_at: DateTime.add(now, -898, :second),
        attempts: 1,
        error: %{"class" => "ToolFailed", "message" => "demo failure"}
      )

    ok ++ [failed]
  end

  defp mine_payload(project) do
    %{"source" => "/demo/projects/#{project}", "wing" => project, "mode" => "projects"}
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

  # Deterministic 32-hex ids.
  defp id(n), do: Base.encode16(:crypto.hash(:md5, "butler-demo-#{n}"), case: :lower)

  # Database

  defp create_queue!(path, jobs) do
    {:ok, db} = Store.open(path)

    try do
      Enum.each(jobs, &insert!(db, &1))
    after
      Store.close(db)
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

defmodule Butler.Commands.SubmitTest do
  use ExUnit.Case, async: false

  import Mox

  alias Butler.Commands.Submit
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  @job_id "0d500eb9b28b411bb8fc0e4a3f15cecb"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, fixture: DaemonFixture.install!(running: true)}
  end

  defp submitted(kind),
    do: {:ok, %{status: 0, output: "Submitted daemon job #{@job_id} (#{kind})\n"}}

  describe "submit_mine/1" do
    test "runs the CLI with an argument list and returns the job id", %{fixture: f} do
      expect(Butler.CLIMock, :run, fn args, opts ->
        assert args == [
                 "--palace",
                 f.palace,
                 "mine",
                 "/tmp/synthetic/project",
                 "--daemon",
                 "--background",
                 "--dry-run"
               ]

        assert is_integer(opts[:timeout])
        submitted("mine")
      end)

      assert Submit.mine(%{dir: "/tmp/synthetic/project", dry_run: true}) == {:ok, @job_id}
    end

    test "invalid input never reaches the CLI" do
      assert Submit.mine(%{dir: "relative"}) == {:error, {:invalid, :dir}}
    end

    test "a non-zero exit is a CLI error carrying the output" do
      expect(Butler.CLIMock, :run, fn _args, _opts ->
        {:ok, %{status: 2, output: "mempalace mine: error: boom\n"}}
      end)

      assert Submit.mine(%{dir: "/tmp/p"}) == {:error, {:cli, "mempalace mine: error: boom\n"}}
    end

    test "an unparseable output is a CLI error" do
      expect(Butler.CLIMock, :run, fn _args, _opts ->
        {:ok, %{status: 0, output: "something else\n"}}
      end)

      assert Submit.mine(%{dir: "/tmp/p"}) == {:error, {:cli, "something else\n"}}
    end

    test "a timeout is a CLI error" do
      expect(Butler.CLIMock, :run, fn _args, _opts -> {:error, {:timeout, "partial"}} end)

      assert {:error, {:cli, message}} = Submit.mine(%{dir: "/tmp/p"})
      assert message =~ "timed out"
      assert message =~ "partial"
    end

    test "a missing executable is a CLI error" do
      expect(Butler.CLIMock, :run, fn _args, _opts ->
        {:error, {:executable_not_found, "mempalace"}}
      end)

      assert {:error, {:cli, message}} = Submit.mine(%{dir: "/tmp/p"})
      assert message =~ "mempalace"
    end
  end

  describe "duplicates" do
    test "refuses a mine identical to a queued or running one", %{fixture: f} do
      QueueFixture.insert_job!(f.queue,
        id: "existing-1",
        state: "running",
        payload_json: %{
          "agent" => "mempalace",
          "dry_run" => false,
          "extract" => "exchange",
          "include_ignored" => [],
          "limit" => 0,
          "max_chunks_per_file" => nil,
          "mode" => "projects",
          "no_gitignore" => false,
          "palace_path" => f.palace,
          "redetect_origin" => false,
          "source" => "/tmp/synthetic/project",
          "wing" => nil
        }
      )

      # No CLI expectation: the CLI must not be called.
      assert Submit.mine(%{dir: "/tmp/synthetic/project"}) == {:error, {:duplicate, "existing-1"}}
    end

    test "a different option makes it a different job", %{fixture: f} do
      QueueFixture.insert_job!(f.queue,
        state: "queued",
        payload_json: %{
          "source" => "/tmp/synthetic/project",
          "mode" => "projects",
          "dry_run" => false
        }
      )

      expect(Butler.CLIMock, :run, fn _args, _opts -> submitted("mine") end)

      assert Submit.mine(%{dir: "/tmp/synthetic/project", dry_run: true}) == {:ok, @job_id}
    end

    test "a finished identical job is not a duplicate", %{fixture: f} do
      QueueFixture.insert_job!(f.queue,
        state: "succeeded",
        payload_json: %{"source" => "/tmp/synthetic/project", "mode" => "projects"}
      )

      expect(Butler.CLIMock, :run, fn _args, _opts -> submitted("mine") end)

      assert Submit.mine(%{dir: "/tmp/synthetic/project"}) == {:ok, @job_id}
    end

    test "a different kind is not a duplicate", %{fixture: f} do
      QueueFixture.insert_job!(f.queue,
        kind: "sweep",
        state: "queued",
        payload_json: %{"target" => "/tmp/x"}
      )

      expect(Butler.CLIMock, :run, fn _args, _opts -> submitted("mine") end)
      assert Submit.mine(%{dir: "/tmp/x"}) == {:ok, @job_id}
    end

    test "works without any queue database" do
      DaemonFixture.install!(queue: false)
      expect(Butler.CLIMock, :run, fn _args, _opts -> submitted("mine") end)

      assert Submit.mine(%{dir: "/tmp/p"}) == {:ok, @job_id}
    end
  end

  describe "submit_sweep/1" do
    test "submits a sweep" do
      expect(Butler.CLIMock, :run, fn [
                                        "--palace",
                                        _,
                                        "sweep",
                                        "/tmp/t",
                                        "--daemon",
                                        "--background"
                                      ],
                                      _ ->
        submitted("sweep")
      end)

      assert Submit.sweep(%{target: "/tmp/t"}) == {:ok, @job_id}
    end

    test "refuses an identical active sweep", %{fixture: f} do
      QueueFixture.insert_job!(f.queue,
        id: "sw-1",
        kind: "sweep",
        state: "queued",
        payload_json: %{"target" => "/tmp/t"}
      )

      assert Submit.sweep(%{target: "/tmp/t"}) == {:error, {:duplicate, "sw-1"}}
    end
  end

  describe "submit_sync/1" do
    test "submits a dry-run sync only" do
      expect(Butler.CLIMock, :run, fn args, _ ->
        assert "--dry-run" in args
        refute "--apply" in args
        submitted("sync")
      end)

      assert Submit.sync(%{wing: "synthetic"}) == {:ok, @job_id}
    end

    test "refuses an identical active sync", %{fixture: f} do
      QueueFixture.insert_job!(f.queue,
        id: "sy-1",
        kind: "sync",
        state: "running",
        payload_json: %{"dir" => nil, "dry_run" => true, "root" => [], "wing" => "synthetic"}
      )

      assert Submit.sync(%{wing: "synthetic"}) == {:error, {:duplicate, "sy-1"}}
    end
  end

  describe "parse_job_id/1" do
    test "extracts the id from the CLI output" do
      assert Submit.parse_job_id("Submitted daemon job abc123 (mine)\n") == {:ok, "abc123"}

      assert Submit.parse_job_id("noise\nSubmitted daemon job abc123 (sweep)\n") ==
               {:ok, "abc123"}
    end

    test "rejects anything else" do
      assert Submit.parse_job_id("") == :error
      assert Submit.parse_job_id("Submitted daemon job (mine)") == :error
      assert Submit.parse_job_id("Submitted daemon job ../../etc (mine)") == :error
    end
  end
end

defmodule Butler.Jobs.KindsTest do
  use ExUnit.Case, async: false

  alias Butler.Jobs.Kinds

  @palace "/tmp/synthetic/palace"

  defp opts, do: [palace: @palace]

  describe "mine/2" do
    test "builds the minimal daemon submission" do
      assert Kinds.mine(%{dir: "/tmp/synthetic/project"}, opts()) ==
               {:ok,
                [
                  "--palace",
                  @palace,
                  "mine",
                  "/tmp/synthetic/project",
                  "--daemon",
                  "--background"
                ]}
    end

    test "adds every optional flag in a stable order" do
      assert {:ok, args} =
               Kinds.mine(
                 %{
                   dir: "/tmp/synthetic/project",
                   mode: "convos",
                   wing: "synthetic",
                   agent: "tester",
                   dry_run: true,
                   limit: 5,
                   no_gitignore: true,
                   include_ignored: ["docs", "notes"],
                   extract: "general",
                   max_chunks_per_file: 100,
                   redetect_origin: true
                 },
                 opts()
               )

      assert args == [
               "--palace",
               @palace,
               "mine",
               "/tmp/synthetic/project",
               "--daemon",
               "--background",
               "--mode",
               "convos",
               "--wing",
               "synthetic",
               "--agent",
               "tester",
               "--dry-run",
               "--limit",
               "5",
               "--no-gitignore",
               "--include-ignored",
               "docs,notes",
               "--extract",
               "general",
               "--max-chunks-per-file",
               "100",
               "--redetect-origin"
             ]
    end

    test "omits false and nil options" do
      assert {:ok, args} =
               Kinds.mine(
                 %{dir: "/tmp/p", dry_run: false, wing: nil, mode: nil, limit: nil},
                 opts()
               )

      refute "--dry-run" in args
      refute "--wing" in args
      refute "--mode" in args
      refute "--limit" in args
    end

    test "always routes through the daemon in the background" do
      {:ok, args} = Kinds.mine(%{dir: "/tmp/p"}, opts())
      assert "--daemon" in args and "--background" in args
      refute "--direct" in args
    end

    test "accepts only whitelisted modes and extract strategies" do
      for mode <- ~w(projects convos extract) do
        assert {:ok, _} = Kinds.mine(%{dir: "/tmp/p", mode: mode}, opts())
      end

      assert Kinds.mine(%{dir: "/tmp/p", mode: "bogus"}, opts()) == {:error, {:invalid, :mode}}
      assert Kinds.mine(%{dir: "/tmp/p", extract: "x"}, opts()) == {:error, {:invalid, :extract}}
    end

    test "refuses values that could be parsed as options" do
      assert Kinds.mine(%{dir: "-rf"}, opts()) == {:error, {:invalid, :dir}}

      assert Kinds.mine(%{dir: "/tmp/p", wing: "--dry-run"}, opts()) ==
               {:error, {:invalid, :wing}}

      assert Kinds.mine(%{dir: "/tmp/p", agent: "-x"}, opts()) == {:error, {:invalid, :agent}}

      assert Kinds.mine(%{dir: "/tmp/p", include_ignored: ["ok", "--evil"]}, opts()) ==
               {:error, {:invalid, :include_ignored}}
    end

    test "refuses relative directories and NUL bytes" do
      assert Kinds.mine(%{dir: "relative/dir"}, opts()) == {:error, {:invalid, :dir}}
      assert Kinds.mine(%{dir: "/tmp/a\0b"}, opts()) == {:error, {:invalid, :dir}}
    end

    test "refuses non positive or non integer numbers" do
      assert Kinds.mine(%{dir: "/tmp/p", limit: 0}, opts()) == {:error, {:invalid, :limit}}
      assert Kinds.mine(%{dir: "/tmp/p", limit: -3}, opts()) == {:error, {:invalid, :limit}}
      assert Kinds.mine(%{dir: "/tmp/p", limit: "5"}, opts()) == {:error, {:invalid, :limit}}

      assert Kinds.mine(%{dir: "/tmp/p", max_chunks_per_file: 0}, opts()) ==
               {:error, {:invalid, :max_chunks_per_file}}
    end

    test "requires a directory and rejects unknown options" do
      assert Kinds.mine(%{}, opts()) == {:error, {:invalid, :dir}}

      assert Kinds.mine(%{dir: "/tmp/p", direct: true}, opts()) ==
               {:error, {:unknown_option, :direct}}
    end
  end

  describe "sweep/2" do
    test "builds the daemon submission" do
      assert Kinds.sweep(%{target: "/tmp/synthetic/transcripts"}, opts()) ==
               {:ok,
                [
                  "--palace",
                  @palace,
                  "sweep",
                  "/tmp/synthetic/transcripts",
                  "--daemon",
                  "--background"
                ]}
    end

    test "validates the target" do
      assert Kinds.sweep(%{target: "-x"}, opts()) == {:error, {:invalid, :target}}
      assert Kinds.sweep(%{target: "relative"}, opts()) == {:error, {:invalid, :target}}
      assert Kinds.sweep(%{}, opts()) == {:error, {:invalid, :target}}
    end
  end

  describe "sync/2" do
    test "is always a dry run" do
      assert Kinds.sync(%{}, opts()) ==
               {:ok, ["--palace", @palace, "sync", "--daemon", "--background", "--dry-run"]}
    end

    test "adds the wing and repeatable roots" do
      assert {:ok, args} = Kinds.sync(%{wing: "synthetic", roots: ["/tmp/a", "/tmp/b"]}, opts())

      assert args == [
               "--palace",
               @palace,
               "sync",
               "--daemon",
               "--background",
               "--dry-run",
               "--wing",
               "synthetic",
               "--root",
               "/tmp/a",
               "--root",
               "/tmp/b"
             ]
    end

    test "--apply is impossible, however it is requested" do
      assert Kinds.sync(%{apply: true}, opts()) == {:error, {:unknown_option, :apply}}
      assert Kinds.sync(%{dry_run: false}, opts()) == {:error, {:unknown_option, :dry_run}}
      assert Kinds.sync(%{wing: "--apply"}, opts()) == {:error, {:invalid, :wing}}
      assert Kinds.sync(%{roots: ["--apply"]}, opts()) == {:error, {:invalid, :roots}}
    end

    test "no builder can ever produce --apply" do
      inputs = [
        Kinds.mine(%{dir: "/tmp/p", wing: "apply", agent: "apply"}, opts()),
        Kinds.sweep(%{target: "/tmp/apply"}, opts()),
        Kinds.sync(%{wing: "apply", roots: ["/tmp/apply"]}, opts())
      ]

      for {:ok, args} <- inputs, do: refute("--apply" in args)
    end
  end

  test "uses the configured palace by default" do
    previous = Application.fetch_env(:butler, :palace_path)
    Application.put_env(:butler, :palace_path, "/tmp/configured/palace")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:butler, :palace_path, value)
        :error -> Application.delete_env(:butler, :palace_path)
      end
    end)

    assert {:ok, ["--palace", "/tmp/configured/palace" | _]} = Kinds.sync(%{})
  end
end

defmodule Butler.Jobs.KindsArgvTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Kinds

  @palace "/tmp/synthetic/palace"
  @opts [palace: @palace]

  test "mine builds a direct argv from a decoded payload" do
    payload = %{
      "source" => "/tmp/synthetic/project",
      "mode" => "convos",
      "wing" => "w",
      "dry_run" => true,
      "limit" => 5,
      "include_ignored" => ["a", "b"]
    }

    assert {:ok, argv} = Kinds.argv("mine", payload, @opts)

    assert argv == [
             "--palace",
             @palace,
             "mine",
             "/tmp/synthetic/project",
             "--direct",
             "--mode",
             "convos",
             "--wing",
             "w",
             "--dry-run",
             "--limit",
             "5",
             "--include-ignored",
             "a,b"
           ]
  end

  test "atom keys work too and sweep is direct" do
    assert {:ok, ["--palace", @palace, "sweep", "/tmp/s", "--direct"]} =
             Kinds.argv("sweep", %{target: "/tmp/s"}, @opts)
  end

  test "mine, sweep and sync never carry --daemon or --background" do
    payloads = [
      {"mine", %{"source" => "/tmp/p"}},
      {"sweep", %{"target" => "/tmp/p"}},
      {"sync", %{}},
      {"sync", %{"wing" => "w", "dry_run" => false}}
    ]

    for {kind, payload} <- payloads do
      assert {:ok, argv} = Kinds.argv(kind, payload, @opts)
      assert "--direct" in argv
      refute "--daemon" in argv
      refute "--background" in argv
    end
  end

  test "sync defaults to --dry-run and applies only on an explicit false" do
    assert {:ok, argv} = Kinds.argv("sync", %{}, @opts)
    assert argv == ["--palace", @palace, "sync", "--direct", "--dry-run"]
    refute "--apply" in argv

    assert {:ok, argv} = Kinds.argv("sync", %{"dry_run" => true, "roots" => ["/tmp/r"]}, @opts)
    assert argv == ["--palace", @palace, "sync", "--direct", "--dry-run", "--root", "/tmp/r"]

    assert {:ok, argv} = Kinds.argv("sync", %{"dry_run" => false, "wing" => "w"}, @opts)
    assert argv == ["--palace", @palace, "sync", "--direct", "--apply", "--wing", "w"]
  end

  test "sync --apply needs a wing or a root; dry_run must be a boolean" do
    assert Kinds.argv("sync", %{"dry_run" => false}, @opts) == {:error, {:invalid, :wing}}
    assert Kinds.argv("sync", %{"dry_run" => "no"}, @opts) == {:error, {:invalid, :dry_run}}
  end

  test "maintenance kinds" do
    assert {:ok, ["--palace", @palace, "repair", "--yes"]} = Kinds.argv("repair", %{}, @opts)

    assert {:ok, ["--palace", @palace, "repair", "--yes", "--dry-run"]} =
             Kinds.argv("repair", %{"dry_run" => true}, @opts)

    assert {:ok, ["--palace", @palace, "compress", "--dry-run", "--wing", "w"]} =
             Kinds.argv("compress", %{"wing" => "w", "dry_run" => true}, @opts)

    assert {:ok, ["--palace", @palace, "migrate-wings", "--yes"]} =
             Kinds.argv("migrate-wings", %{}, @opts)
  end

  test "refuses unknown keys and kinds, bad values and non-maps" do
    assert Kinds.argv("mine", %{"source" => "/tmp/p", "daemon" => true}, @opts) ==
             {:error, {:unknown_option, "daemon"}}

    assert Kinds.argv("repair", %{"force" => true}, @opts) == {:error, {:unknown_option, "force"}}
    assert Kinds.argv("mine", %{"source" => "relative"}, @opts) == {:error, {:invalid, :source}}
    assert Kinds.argv("mine", %{}, @opts) == {:error, {:invalid, :source}}
    assert Kinds.argv("sweep", %{"target" => "-x"}, @opts) == {:error, {:invalid, :target}}
    assert Kinds.argv("mine", "nope", @opts) == {:error, {:invalid, :payload}}
    assert Kinds.argv("diary_write", %{}, @opts) == {:error, :unknown_kind}
  end

  test "kinds, idempotence, timeouts and routing env" do
    assert Enum.sort(Kinds.kinds()) ==
             Enum.sort(~w(mine sweep sync repair compress migrate-wings diary_write mcp_tool))

    assert Kinds.idempotent_kinds() == ~w(mine sweep sync)
    assert Kinds.idempotent?("mine")
    refute Kinds.idempotent?("repair")

    assert Kinds.timeout_ms("mine") == 6 * 3_600_000
    assert Kinds.timeout_ms("sweep") == 2 * 3_600_000
    assert Kinds.timeout_ms("sync") == 3_600_000
    assert Kinds.timeout_ms("mine", %{"mine" => 10}) == 10
    assert Kinds.timeout_ms("mine", %{"mine" => 0}) == 6 * 3_600_000

    assert Kinds.routing_env() == [
             {"MEMPALACE_CLI_WRITE_ROUTING", "direct"},
             {"MEMPALACE_WRITE_ROUTING", "direct"},
             {"MEMPALACE_HUB_FORWARD", "0"}
           ]
  end
end

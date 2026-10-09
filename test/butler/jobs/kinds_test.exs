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

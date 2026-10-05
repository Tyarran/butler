defmodule Butler.Commands.ArgsTest do
  use ExUnit.Case, async: false

  alias Butler.Commands.Args

  @palace "/tmp/synthetic/palace"

  defp opts, do: [palace: @palace]

  describe "mine/2" do
    test "builds the minimal daemon submission" do
      assert Args.mine(%{dir: "/tmp/synthetic/project"}, opts()) ==
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
               Args.mine(
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
               Args.mine(
                 %{dir: "/tmp/p", dry_run: false, wing: nil, mode: nil, limit: nil},
                 opts()
               )

      refute "--dry-run" in args
      refute "--wing" in args
      refute "--mode" in args
      refute "--limit" in args
    end

    test "always routes through the daemon in the background" do
      {:ok, args} = Args.mine(%{dir: "/tmp/p"}, opts())
      assert "--daemon" in args and "--background" in args
      refute "--direct" in args
    end

    test "accepts only whitelisted modes and extract strategies" do
      for mode <- ~w(projects convos extract) do
        assert {:ok, _} = Args.mine(%{dir: "/tmp/p", mode: mode}, opts())
      end

      assert Args.mine(%{dir: "/tmp/p", mode: "bogus"}, opts()) == {:error, {:invalid, :mode}}
      assert Args.mine(%{dir: "/tmp/p", extract: "x"}, opts()) == {:error, {:invalid, :extract}}
    end

    test "refuses values that could be parsed as options" do
      assert Args.mine(%{dir: "-rf"}, opts()) == {:error, {:invalid, :dir}}
      assert Args.mine(%{dir: "/tmp/p", wing: "--dry-run"}, opts()) == {:error, {:invalid, :wing}}
      assert Args.mine(%{dir: "/tmp/p", agent: "-x"}, opts()) == {:error, {:invalid, :agent}}

      assert Args.mine(%{dir: "/tmp/p", include_ignored: ["ok", "--evil"]}, opts()) ==
               {:error, {:invalid, :include_ignored}}
    end

    test "refuses relative directories and NUL bytes" do
      assert Args.mine(%{dir: "relative/dir"}, opts()) == {:error, {:invalid, :dir}}
      assert Args.mine(%{dir: "/tmp/a\0b"}, opts()) == {:error, {:invalid, :dir}}
    end

    test "refuses non positive or non integer numbers" do
      assert Args.mine(%{dir: "/tmp/p", limit: 0}, opts()) == {:error, {:invalid, :limit}}
      assert Args.mine(%{dir: "/tmp/p", limit: -3}, opts()) == {:error, {:invalid, :limit}}
      assert Args.mine(%{dir: "/tmp/p", limit: "5"}, opts()) == {:error, {:invalid, :limit}}

      assert Args.mine(%{dir: "/tmp/p", max_chunks_per_file: 0}, opts()) ==
               {:error, {:invalid, :max_chunks_per_file}}
    end

    test "requires a directory and rejects unknown options" do
      assert Args.mine(%{}, opts()) == {:error, {:invalid, :dir}}

      assert Args.mine(%{dir: "/tmp/p", direct: true}, opts()) ==
               {:error, {:unknown_option, :direct}}
    end
  end

  describe "sweep/2" do
    test "builds the daemon submission" do
      assert Args.sweep(%{target: "/tmp/synthetic/transcripts"}, opts()) ==
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
      assert Args.sweep(%{target: "-x"}, opts()) == {:error, {:invalid, :target}}
      assert Args.sweep(%{target: "relative"}, opts()) == {:error, {:invalid, :target}}
      assert Args.sweep(%{}, opts()) == {:error, {:invalid, :target}}
    end
  end

  describe "sync/2" do
    test "is always a dry run" do
      assert Args.sync(%{}, opts()) ==
               {:ok, ["--palace", @palace, "sync", "--daemon", "--background", "--dry-run"]}
    end

    test "adds the wing and repeatable roots" do
      assert {:ok, args} = Args.sync(%{wing: "synthetic", roots: ["/tmp/a", "/tmp/b"]}, opts())

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
      assert Args.sync(%{apply: true}, opts()) == {:error, {:unknown_option, :apply}}
      assert Args.sync(%{dry_run: false}, opts()) == {:error, {:unknown_option, :dry_run}}
      assert Args.sync(%{wing: "--apply"}, opts()) == {:error, {:invalid, :wing}}
      assert Args.sync(%{roots: ["--apply"]}, opts()) == {:error, {:invalid, :roots}}
    end

    test "no builder can ever produce --apply" do
      inputs = [
        Args.mine(%{dir: "/tmp/p", wing: "apply", agent: "apply"}, opts()),
        Args.sweep(%{target: "/tmp/apply"}, opts()),
        Args.sync(%{wing: "apply", roots: ["/tmp/apply"]}, opts())
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

    assert {:ok, ["--palace", "/tmp/configured/palace" | _]} = Args.sync(%{})
  end
end

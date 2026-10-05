defmodule Butler.Commands.InputTest do
  use ExUnit.Case, async: true

  alias Butler.Commands.Args
  alias Butler.Commands.Input
  alias Butler.Test.QueueFixture

  setup do
    dir = QueueFixture.tmp_dir!()
    file = Path.join(dir, "transcript.jsonl")
    File.write!(file, "")
    {:ok, dir: dir, transcript: file}
  end

  describe "mine/1" do
    test "normalizes a valid form submission", %{dir: dir} do
      params = %{
        "dir" => dir,
        "mode" => "convos",
        "wing" => " synthetic ",
        "agent" => "",
        "dry_run" => "true",
        "limit" => "10",
        "no_gitignore" => "false",
        "include_ignored" => "docs, notes\nextra",
        "extract" => "general",
        "max_chunks_per_file" => "200",
        "redetect_origin" => "on"
      }

      assert {:ok, input} = Input.mine(params)

      assert input == %{
               dir: dir,
               mode: "convos",
               wing: "synthetic",
               agent: nil,
               dry_run: true,
               limit: 10,
               no_gitignore: false,
               include_ignored: ["docs", "notes", "extra"],
               extract: "general",
               max_chunks_per_file: 200,
               redetect_origin: true
             }
    end

    test "only the directory is required", %{dir: dir} do
      assert {:ok, %{dir: ^dir, mode: nil, limit: nil, dry_run: false}} =
               Input.mine(%{"dir" => dir})
    end

    test "requires a directory" do
      assert {:error, %{dir: "can't be blank"}} = Input.mine(%{"dir" => " "})
      assert {:error, %{dir: "can't be blank"}} = Input.mine(%{})
    end

    test "requires an absolute directory that exists", %{dir: dir, transcript: file} do
      assert {:error, %{dir: "must be an absolute path"}} = Input.mine(%{"dir" => "relative/dir"})

      assert {:error, %{dir: "directory does not exist"}} =
               Input.mine(%{"dir" => Path.join(dir, "missing")})

      assert {:error, %{dir: "directory does not exist"}} = Input.mine(%{"dir" => file})
    end

    test "whitelists mode and extract", %{dir: dir} do
      assert {:error, errors} = Input.mine(%{"dir" => dir, "mode" => "bogus", "extract" => "x"})
      assert errors.mode == "must be one of: projects, convos, extract"
      assert errors.extract == "must be one of: exchange, general"
    end

    test "requires positive integers", %{dir: dir} do
      for bad <- ["0", "-1", "abc", "1.5", "12abc"] do
        assert {:error, %{limit: "must be a positive integer"}} =
                 Input.mine(%{"dir" => dir, "limit" => bad})
      end

      assert {:error, %{max_chunks_per_file: "must be a positive integer"}} =
               Input.mine(%{"dir" => dir, "max_chunks_per_file" => "0"})
    end

    test "refuses text values starting with a dash", %{dir: dir} do
      assert {:error, %{wing: "must not start with -"}} =
               Input.mine(%{"dir" => dir, "wing" => "--x"})

      assert {:error, %{agent: "must not start with -"}} =
               Input.mine(%{"dir" => dir, "agent" => "-a"})

      assert {:error, %{include_ignored: "must not start with -"}} =
               Input.mine(%{"dir" => dir, "include_ignored" => "ok,--evil"})
    end

    test "reports every error at once" do
      assert {:error, errors} =
               Input.mine(%{"dir" => "nope", "limit" => "0", "wing" => "-w", "mode" => "z"})

      assert Map.keys(errors) |> Enum.sort() == [:dir, :limit, :mode, :wing]
    end

    test "its output is accepted by the argument builder", %{dir: dir} do
      {:ok, input} = Input.mine(%{"dir" => dir, "limit" => "3", "dry_run" => "true"})
      assert {:ok, _args} = Args.mine(input, palace: "/tmp/p")
    end
  end

  describe "sweep/1" do
    test "accepts an existing file or directory", %{dir: dir, transcript: file} do
      assert {:ok, %{target: ^dir}} = Input.sweep(%{"target" => dir})
      assert {:ok, %{target: ^file}} = Input.sweep(%{"target" => file})
    end

    test "rejects blank, relative and missing targets", %{dir: dir} do
      assert {:error, %{target: "can't be blank"}} = Input.sweep(%{"target" => ""})
      assert {:error, %{target: "must be an absolute path"}} = Input.sweep(%{"target" => "rel"})

      assert {:error, %{target: "path does not exist"}} =
               Input.sweep(%{"target" => Path.join(dir, "nope")})
    end
  end

  describe "sync/1" do
    test "accepts an empty form" do
      assert {:ok, %{wing: nil, roots: []}} = Input.sync(%{})
    end

    test "normalizes wing and roots", %{dir: dir} do
      assert {:ok, %{wing: "synthetic", roots: [^dir]}} =
               Input.sync(%{"wing" => "synthetic", "roots" => dir})
    end

    test "validates roots and wing", %{dir: dir} do
      assert {:error, %{roots: "directory does not exist: " <> _}} =
               Input.sync(%{"roots" => Path.join(dir, "nope")})

      assert {:error, %{roots: "must be an absolute path: rel"}} = Input.sync(%{"roots" => "rel"})
      assert {:error, %{wing: "must not start with -"}} = Input.sync(%{"wing" => "--apply"})
    end

    test "has no way to express an apply or a non dry run" do
      assert {:ok, input} = Input.sync(%{"apply" => "true", "dry_run" => "false"})
      refute Map.has_key?(input, :apply)
      refute Map.has_key?(input, :dry_run)
    end
  end
end

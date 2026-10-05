defmodule Butler.Commands.Args do
  @moduledoc """
  Builds `mempalace` argument lists for the commands Butler can submit to the
  daemon: `mine`, `sweep` and `sync` (dry run only).

  The builders return **argument lists** (never shell strings) and validate
  every value:

    * unknown options are refused, so there is no way to ask for `--apply`
      or `--direct`;
    * `sync` is always forced to `--dry-run`;
    * enumerated values are whitelisted;
    * free text may not start with `-` (it could be parsed as an option) nor
      contain NUL bytes;
    * paths must be absolute;
    * numbers must be positive integers.

  Blank optional values (`nil`, `""`, `false`, `[]`) are omitted.
  """

  alias Butler.Palace

  @modes ~w(projects convos extract)
  @extract_strategies ~w(exchange general)

  @mine_options [
    {:mode, "--mode", {:enum, @modes}},
    {:wing, "--wing", :text},
    {:agent, "--agent", :text},
    {:dry_run, "--dry-run", :flag},
    {:limit, "--limit", :positive_integer},
    {:no_gitignore, "--no-gitignore", :flag},
    {:include_ignored, "--include-ignored", :csv},
    {:extract, "--extract", {:enum, @extract_strategies}},
    {:max_chunks_per_file, "--max-chunks-per-file", :positive_integer},
    {:redetect_origin, "--redetect-origin", :flag}
  ]

  @sync_options [
    {:wing, "--wing", :text},
    {:roots, "--root", {:repeat, :absolute_path}}
  ]

  @type input :: %{optional(atom()) => term()}
  @type result :: {:ok, [String.t()]} | {:error, {:invalid, atom()} | {:unknown_option, atom()}}

  @doc "Allowed values of the `mode` option of `mine`."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "Allowed values of the `extract` option of `mine`."
  @spec extract_strategies() :: [String.t()]
  def extract_strategies, do: @extract_strategies

  @doc """
  Arguments for `mempalace mine <dir> --daemon --background [...]`.

  Accepted keys: `:dir` (required, absolute), `:mode`, `:wing`, `:agent`,
  `:dry_run`, `:limit`, `:no_gitignore`, `:include_ignored` (list of paths),
  `:extract`, `:max_chunks_per_file` and `:redetect_origin`.

  Pass `palace: path` in `opts` to override the configured palace.
  """
  @spec mine(input(), keyword()) :: result()
  def mine(input, opts \\ []) do
    with :ok <- check_keys(input, [:dir | Enum.map(@mine_options, &elem(&1, 0))]),
         {:ok, dir} <- required_path(input, :dir),
         {:ok, rest} <- options(input, @mine_options) do
      {:ok, base(opts) ++ ["mine", dir, "--daemon", "--background"] ++ rest}
    end
  end

  @doc """
  Arguments for `mempalace sweep <target> --daemon --background`.

  Accepted key: `:target` (required, absolute path to a `.jsonl` file or a
  directory).
  """
  @spec sweep(input(), keyword()) :: result()
  def sweep(input, opts \\ []) do
    with :ok <- check_keys(input, [:target]),
         {:ok, target} <- required_path(input, :target) do
      {:ok, base(opts) ++ ["sweep", target, "--daemon", "--background"]}
    end
  end

  @doc """
  Arguments for `mempalace sync --daemon --background --dry-run [...]`.

  `--dry-run` is always present and `--apply` can never be produced.
  Accepted keys: `:wing` and `:roots` (list of absolute paths).
  """
  @spec sync(input(), keyword()) :: result()
  def sync(input, opts \\ []) do
    with :ok <- check_keys(input, Enum.map(@sync_options, &elem(&1, 0))),
         {:ok, rest} <- options(input, @sync_options) do
      {:ok, base(opts) ++ ["sync", "--daemon", "--background", "--dry-run"] ++ rest}
    end
  end

  defp base(opts), do: ["--palace", Keyword.get_lazy(opts, :palace, &Palace.path/0)]

  defp check_keys(input, allowed) do
    case Enum.find(Map.keys(input), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:unknown_option, key}}
    end
  end

  defp required_path(input, key) do
    case validate(:absolute_path, Map.get(input, key)) do
      {:ok, path} -> {:ok, path}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp options(input, specs) do
    Enum.reduce_while(specs, {:ok, []}, fn {key, flag, type}, {:ok, acc} ->
      case option(Map.get(input, key), flag, type) do
        {:ok, args} -> {:cont, {:ok, acc ++ args}}
        :error -> {:halt, {:error, {:invalid, key}}}
      end
    end)
  end

  defp option(value, _flag, _type) when value in [nil, "", false, []], do: {:ok, []}
  defp option(true, flag, :flag), do: {:ok, [flag]}
  defp option(_value, _flag, :flag), do: :error

  defp option(values, flag, {:repeat, type}) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case validate(type, value) do
        {:ok, valid} -> {:cont, {:ok, acc ++ [flag, valid]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp option(value, flag, type) do
    case validate(type, value) do
      {:ok, valid} -> {:ok, [flag, valid]}
      :error -> :error
    end
  end

  defp validate({:enum, allowed}, value) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp validate(:text, value) when is_binary(value), do: safe_text(value)

  defp validate(:positive_integer, value) when is_integer(value) and value > 0,
    do: {:ok, Integer.to_string(value)}

  defp validate(:absolute_path, value) when is_binary(value) do
    with {:ok, path} <- safe_text(value) do
      if Path.type(path) == :absolute, do: {:ok, path}, else: :error
    end
  end

  defp validate(:csv, values) when is_list(values) do
    if Enum.all?(values, &csv_item?/1), do: {:ok, Enum.join(values, ",")}, else: :error
  end

  defp validate(_type, _value), do: :error

  defp csv_item?(value),
    do: match?({:ok, _}, validate(:text, value)) and not String.contains?(value, ",")

  # Non-empty text that cannot be mistaken for an option or truncate a C string.
  defp safe_text(value) do
    if value == "" or String.starts_with?(value, "-") or String.contains?(value, <<0>>) do
      :error
    else
      {:ok, value}
    end
  end
end

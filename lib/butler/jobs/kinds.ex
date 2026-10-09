defmodule Butler.Jobs.Kinds do
  @moduledoc """
  Job kinds: validation of their payloads and `mempalace` argument lists.

  `argv/3` is what the worker runs for a queued job (always `--direct`, see
  `routing_env/0`); it accepts payloads with atom or string keys (decoded
  `payload_json`). `validate_payload/2` applies the same rules at submit time.

  `argv/3` returns **argument lists** (never shell strings) and validates
  every value:

    * unknown options are refused;
    * `sync` is a dry run unless `dry_run` is explicitly `false`;
    * enumerated values are whitelisted;
    * free text may not start with `-` (it could be parsed as an option) nor
      contain NUL bytes;
    * paths must be absolute;
    * numbers must be positive integers.

  Blank optional values (`nil`, `""`, `false`, `[]`) are omitted.
  """

  alias Butler.Jobs.Runner
  alias Butler.Palace

  @modes ~w(projects convos extract)
  @extract_strategies ~w(exchange general)

  @kinds ~w(mine sweep sync repair compress migrate-wings diary_write mcp_tool)
  @api_kinds ~w(mine sweep sync diary_write mcp_tool)
  @idempotent_kinds ~w(mine sweep sync)
  @maintenance_kinds ~w(repair compress migrate-wings)
  @sensitive_kinds ~w(diary_write mcp_tool)

  @default_timeouts_ms %{
    "mine" => 6 * 3_600_000,
    "sweep" => 2 * 3_600_000,
    "sync" => 3_600_000,
    "repair" => 6 * 3_600_000,
    "compress" => 6 * 3_600_000,
    "migrate-wings" => 6 * 3_600_000,
    "diary_write" => 600_000,
    "mcp_tool" => 600_000
  }

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

  @compress_options [{:wing, "--wing", :text}]

  @type input :: %{optional(atom()) => term()}
  @type result ::
          {:ok, [String.t()]}
          | {:error, {:invalid, atom()} | {:unknown_option, atom() | String.t()} | :unknown_kind}

  @doc "Every job kind the worker can run."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Kinds the HTTP API accepts; the maintenance kinds are UI-only."
  @spec api_kinds() :: [String.t()]
  def api_kinds, do: @api_kinds

  @doc "Whether the HTTP API accepts jobs of `kind`."
  @spec api_kind?(term()) :: boolean()
  def api_kind?(kind), do: kind in @api_kinds

  @doc "Kinds that may safely run again after a crash (`recover_running`, shutdown)."
  @spec idempotent_kinds() :: [String.t()]
  def idempotent_kinds, do: @idempotent_kinds

  @doc "Kinds that put the MCP proxy in maintenance mode (dry-runs included)."
  @spec maintenance_kinds() :: [String.t()]
  def maintenance_kinds, do: @maintenance_kinds

  @doc "Whether jobs of `kind` gate the MCP proxy while they run."
  @spec maintenance?(term()) :: boolean()
  def maintenance?(kind), do: kind in @maintenance_kinds

  @doc """
  Whether the payload of jobs of `kind` is verbatim user content (`diary_write`,
  `mcp_tool`): the dashboard never shows it.
  """
  @spec sensitive_payload?(term()) :: boolean()
  def sensitive_payload?(kind), do: kind in @sensitive_kinds

  @doc "Whether jobs of `kind` can be re-run safely."
  @spec idempotent?(String.t()) :: boolean()
  def idempotent?(kind), do: kind in @idempotent_kinds

  @doc """
  Timeout, in milliseconds, of a job of `kind`. `overrides` is a map of kind to
  milliseconds; the timeout is never infinite.
  """
  @spec timeout_ms(String.t(), %{optional(String.t()) => pos_integer()}) :: pos_integer()
  def timeout_ms(kind, overrides \\ %{}) do
    case Map.get(overrides, kind) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> Map.get(@default_timeouts_ms, kind, 3_600_000)
    end
  end

  @doc "Environment forcing direct write routing on every spawned `mempalace` process."
  @spec routing_env() :: [{String.t(), String.t()}]
  defdelegate routing_env, to: Butler.OSProcess

  @doc "Allowed values of the `mode` option of `mine`."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "Allowed values of the `extract` option of `mine`."
  @spec extract_strategies() :: [String.t()]
  def extract_strategies, do: @extract_strategies

  @doc """
  Arguments of the `mempalace` process running a job of `kind` with `payload`.

  Every command with routing flags gets `--direct` (never `--daemon` nor
  `--background`). Payloads:

    * `mine` - `source` (required, absolute) and the options of `mine/2`;
    * `sweep` - `target` (required, absolute);
    * `sync` - `wing`, `roots`, `dry_run`; **`dry_run` defaults to true**,
      `--apply` is produced only by an explicit `false` and needs a `wing` or
      a root;
    * `repair`, `compress` (`wing`), `migrate-wings` - `dry_run` (default
      false); `repair` and `migrate-wings` get `--yes` (no prompt).

  Unknown keys are refused. Pass `palace: path` in `opts` to override the
  configured palace.
  """
  @spec argv(String.t(), map(), keyword()) :: result()
  def argv(kind, payload, opts \\ [])

  def argv("mine", payload, opts) do
    with {:ok, input} <- normalize(payload, [:source | Enum.map(@mine_options, &elem(&1, 0))]),
         {:ok, source} <- required_path(input, :source),
         {:ok, rest} <- options(input, @mine_options) do
      {:ok, base(opts) ++ ["mine", source, "--direct"] ++ rest}
    end
  end

  def argv("sweep", payload, opts) do
    with {:ok, input} <- normalize(payload, [:target]),
         {:ok, target} <- required_path(input, :target) do
      {:ok, base(opts) ++ ["sweep", target, "--direct"]}
    end
  end

  def argv("sync", payload, opts) do
    with {:ok, input} <- normalize(payload, [:dry_run | Enum.map(@sync_options, &elem(&1, 0))]),
         {:ok, rest} <- options(input, @sync_options),
         {:ok, mode} <- sync_mode(input) do
      {:ok, base(opts) ++ ["sync", "--direct", mode] ++ rest}
    end
  end

  def argv("repair", payload, opts), do: maintenance("repair", ["--yes"], [], payload, opts)
  def argv("compress", payload, opts), do: maintenance("compress", [], [:wing], payload, opts)

  def argv("migrate-wings", payload, opts),
    do: maintenance("migrate-wings", ["--yes"], [], payload, opts)

  def argv(_kind, _payload, _opts), do: {:error, :unknown_kind}

  @type payload_error :: :unknown_kind | {:invalid, field :: String.t() | nil, String.t()}

  @doc """
  Validates the payload of a job of `kind` at submit time, with the very rules
  the worker applies when it runs the job (`argv/3`, `Runner.MCP.request/3`).

  A missing payload is an empty one. A client-supplied palace (`palace_path`,
  `palace`) is refused: Butler always uses its own. Returns the payload to
  store; for `sync`, `dry_run` is made explicit (`true` unless given).
  """
  @spec validate_payload(term(), term()) :: {:ok, map()} | {:error, payload_error()}
  def validate_payload(kind, payload) when kind in @kinds do
    case payload || %{} do
      %{} = payload ->
        with :ok <- no_palace(payload), do: validate_kind(kind, payload)

      _other ->
        {:error, {:invalid, "payload", "payload must be an object"}}
    end
  end

  def validate_payload(_kind, _payload), do: {:error, :unknown_kind}

  defp no_palace(payload) do
    case Enum.find(Map.keys(payload), &(to_string(&1) in ~w(palace_path palace))) do
      nil ->
        :ok

      key ->
        {:error,
         {:invalid, to_string(key), "#{key} is not accepted: Butler always uses its own palace"}}
    end
  end

  defp validate_kind(kind, payload) when kind in ~w(diary_write mcp_tool) do
    case Runner.MCP.request(kind, payload) do
      {:ok, _name, _arguments} -> {:ok, payload}
      {:error, message} -> {:error, {:invalid, message_field(message), message}}
    end
  end

  defp validate_kind(kind, payload) do
    with :ok <- sync_scope(kind, payload),
         {:ok, _argv} <- argv(kind, payload, palace: "/validation") do
      {:ok, if(kind == "sync", do: sync_default(payload), else: payload)}
    else
      {:error, {:invalid, key}} -> {:error, {:invalid, to_string(key), "#{key} is invalid"}}
      {:error, {:unknown_option, key}} -> {:error, {:invalid, to_string(key), "unknown key"}}
      {:error, {:invalid, _, _}} = error -> error
    end
  end

  defp sync_scope("sync", payload) do
    values = Map.new(payload, fn {key, value} -> {to_string(key), value} end)

    if Map.get(values, "dry_run") == false and blank?(Map.get(values, "wing")) and
         blank?(Map.get(values, "roots")) do
      {:error, {:invalid, "dry_run", "applying a sync (dry_run false) needs a wing or roots"}}
    else
      :ok
    end
  end

  defp sync_scope(_kind, _payload), do: :ok

  defp sync_default(payload) do
    if Enum.any?(Map.keys(payload), &(to_string(&1) == "dry_run")),
      do: payload,
      else: Map.put(payload, "dry_run", true)
  end

  # The MCP request builder only returns messages: recover the key they name.
  defp message_field("unknown payload key: " <> key), do: key
  defp message_field("tool is not in the write allowlist" <> _rest), do: "name"
  defp message_field("arguments " <> _rest), do: "arguments"

  defp message_field(message) do
    case String.split(message, " ", parts: 2) do
      [key, "must be" <> _rest] -> key
      _other -> nil
    end
  end

  defp maintenance(command, fixed, extra_keys, payload, opts) do
    specs = Enum.filter(@compress_options, &(elem(&1, 0) in extra_keys))

    with {:ok, input} <- normalize(payload, [:dry_run | Enum.map(specs, &elem(&1, 0))]),
         {:ok, rest} <- options(input, [{:dry_run, "--dry-run", :flag} | specs]) do
      {:ok, base(opts) ++ [command] ++ fixed ++ rest}
    end
  end

  # `--dry-run` unless `dry_run` is explicitly false; `--apply` then needs a scope.
  defp sync_mode(input) do
    case Map.get(input, :dry_run) do
      value when value in [nil, true] ->
        {:ok, "--dry-run"}

      false ->
        if blank?(Map.get(input, :wing)) and blank?(Map.get(input, :roots)),
          do: {:error, {:invalid, :wing}},
          else: {:ok, "--apply"}

      _other ->
        {:error, {:invalid, :dry_run}}
    end
  end

  defp blank?(value), do: value in [nil, "", []]

  # Keys of a payload (atoms or strings) restricted to `allowed`; never creates atoms.
  defp normalize(payload, allowed) when is_map(payload) do
    Enum.reduce_while(payload, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Enum.find(allowed, &(&1 == key or Atom.to_string(&1) == key)) do
        nil -> {:halt, {:error, {:unknown_option, key}}}
        atom -> {:cont, {:ok, Map.put(acc, atom, value)}}
      end
    end)
  end

  defp normalize(_payload, _allowed), do: {:error, {:invalid, :payload}}

  defp base(opts), do: ["--palace", Keyword.get_lazy(opts, :palace, &Palace.path/0)]

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

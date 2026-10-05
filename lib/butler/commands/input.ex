defmodule Butler.Commands.Input do
  @moduledoc """
  Validates and normalizes form submissions (string params) into the maps
  accepted by `Butler.Commands.Args`.

  Each function returns `{:ok, input}` or `{:error, errors}` where `errors`
  maps a field to a human message, ready to feed `Phoenix.Component.to_form/2`.

  Rules: paths must be absolute and exist; `mode` and `extract` are
  whitelisted; numbers must be positive integers; free text may not start
  with `-`. `sync` has no way to express `--apply` or a non dry run: such
  params are ignored.

  Ecto is deliberately not used: there is no persistence and the rules above
  are simple enough for plain functions.
  """

  alias Butler.Commands.Args

  @true_values ~w(true on 1 yes)

  @type errors :: %{optional(atom()) => String.t()}

  @doc "Validates the params of the `mine` form."
  @spec mine(map()) :: {:ok, map()} | {:error, errors()}
  def mine(params) do
    [
      {:dir, directory(params, :dir, required: true)},
      {:mode, enum(params, :mode, Args.modes())},
      {:wing, text(params, :wing)},
      {:agent, text(params, :agent)},
      {:dry_run, {:ok, boolean(params, :dry_run)}},
      {:limit, positive_integer(params, :limit)},
      {:no_gitignore, {:ok, boolean(params, :no_gitignore)}},
      {:include_ignored, text_list(params, :include_ignored)},
      {:extract, enum(params, :extract, Args.extract_strategies())},
      {:max_chunks_per_file, positive_integer(params, :max_chunks_per_file)},
      {:redetect_origin, {:ok, boolean(params, :redetect_origin)}}
    ]
    |> collect()
  end

  @doc "Validates the params of the `sweep` form."
  @spec sweep(map()) :: {:ok, map()} | {:error, errors()}
  def sweep(params) do
    collect(target: existing_path(params, :target))
  end

  @doc "Validates the params of the `sync` (dry run) form."
  @spec sync(map()) :: {:ok, map()} | {:error, errors()}
  def sync(params) do
    collect(wing: text(params, :wing), roots: directories(params, :roots))
  end

  defp collect(results) do
    {values, errors} =
      Enum.reduce(results, {%{}, %{}}, fn
        {key, {:ok, value}}, {values, errors} -> {Map.put(values, key, value), errors}
        {key, {:error, message}}, {values, errors} -> {values, Map.put(errors, key, message)}
      end)

    if errors == %{}, do: {:ok, values}, else: {:error, errors}
  end

  defp raw(params, key),
    do: params |> Map.get(Atom.to_string(key), Map.get(params, key)) |> trim()

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp boolean(params, key), do: raw(params, key) in @true_values

  defp text(params, key) do
    case raw(params, key) do
      "" -> {:ok, nil}
      "-" <> _ -> {:error, "must not start with -"}
      value -> if nul?(value), do: {:error, "is invalid"}, else: {:ok, value}
    end
  end

  defp text_list(params, key) do
    items = params |> raw(key) |> split()

    cond do
      Enum.any?(items, &String.starts_with?(&1, "-")) -> {:error, "must not start with -"}
      Enum.any?(items, &nul?/1) -> {:error, "is invalid"}
      true -> {:ok, items}
    end
  end

  defp enum(params, key, allowed) do
    case raw(params, key) do
      "" ->
        {:ok, nil}

      value ->
        if value in allowed,
          do: {:ok, value},
          else: {:error, "must be one of: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp positive_integer(params, key) do
    case raw(params, key) do
      "" ->
        {:ok, nil}

      value ->
        case Integer.parse(value) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, "must be a positive integer"}
        end
    end
  end

  defp directory(params, key, opts) do
    required? = Keyword.get(opts, :required, false)

    case raw(params, key) do
      "" -> if required?, do: {:error, "can't be blank"}, else: {:ok, nil}
      path -> check_path(path, &File.dir?/1, "directory does not exist")
    end
  end

  defp existing_path(params, key) do
    case raw(params, key) do
      "" -> {:error, "can't be blank"}
      path -> check_path(path, &File.exists?/1, "path does not exist")
    end
  end

  defp directories(params, key) do
    params
    |> raw(key)
    |> split()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case check_path(
             path,
             &File.dir?/1,
             "directory does not exist: #{path}",
             "must be an absolute path: #{path}"
           ) do
        {:ok, valid} -> {:cont, {:ok, acc ++ [valid]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp check_path(path, exists?, missing_message, relative_message \\ "must be an absolute path") do
    cond do
      nul?(path) or String.starts_with?(path, "-") -> {:error, "is invalid"}
      Path.type(path) != :absolute -> {:error, relative_message}
      exists?.(path) -> {:ok, path}
      true -> {:error, missing_message}
    end
  end

  defp split(value),
    do:
      value
      |> String.split(~r/[,\n]/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp nul?(value), do: String.contains?(value, <<0>>)
end

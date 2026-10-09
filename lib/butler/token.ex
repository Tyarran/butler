defmodule Butler.Token do
  @moduledoc """
  The API bearer token, generated and owned by Butler.

  Stored in the Butler state directory (see `Butler.Paths`), mode 600, 32
  random bytes url-base64 encoded. The file is created empty, chmod-ed to 600
  and only then written, so the secret is never world-readable. This is
  **Butler's own** token; the MemPalace daemon `token` is never read.
  """

  alias Butler.Paths

  @token_bytes 32

  @doc """
  Returns the token, creating the state directory and the token file when
  missing.
  """
  @spec ensure(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure(path \\ Paths.token_path()) do
    case read(path) do
      {:ok, token} -> {:ok, token}
      {:error, :enoent} -> create(path)
      {:error, _reason} = error -> error
    end
  end

  @doc "Reads an existing token (trailing whitespace trimmed)."
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read(path \\ Paths.token_path()) do
    with {:ok, content} <- File.read(path) do
      case String.trim(content) do
        "" -> {:error, :empty_token}
        token -> {:ok, token}
      end
    end
  end

  @doc "Constant-time comparison of a presented token with the expected one."
  @spec valid?(term(), String.t()) :: boolean()
  def valid?(presented, expected) when is_binary(presented) and is_binary(expected),
    do: Plug.Crypto.secure_compare(presented, expected)

  def valid?(_presented, _expected), do: false

  defp create(path) do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    with :ok <- Paths.ensure_dir(Path.dirname(path)),
         :ok <- File.write(path, ""),
         :ok <- File.chmod(path, Paths.file_mode()),
         :ok <- File.write(path, token) do
      {:ok, token}
    end
  end
end

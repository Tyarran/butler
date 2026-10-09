defmodule Butler.TokenTest do
  use ExUnit.Case, async: true

  alias Butler.Token

  @tag :tmp_dir
  test "ensure/1 creates the state dir (700) and the token file (600)", %{tmp_dir: tmp} do
    path = Path.join([tmp, "state", "token"])

    assert {:ok, token} = Token.ensure(path)
    assert byte_size(token) >= 43
    assert File.read!(path) == token
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
  end

  @tag :tmp_dir
  test "ensure/1 is stable and does not rotate an existing token", %{tmp_dir: tmp} do
    path = Path.join(tmp, "token")

    assert {:ok, first} = Token.ensure(path)
    assert {:ok, ^first} = Token.ensure(path)
  end

  @tag :tmp_dir
  test "ensure/1 generates distinct tokens", %{tmp_dir: tmp} do
    {:ok, a} = Token.ensure(Path.join(tmp, "a"))
    {:ok, b} = Token.ensure(Path.join(tmp, "b"))

    refute a == b
  end

  @tag :tmp_dir
  test "read/1 trims whitespace and refuses an empty file", %{tmp_dir: tmp} do
    path = Path.join(tmp, "token")
    File.write!(path, "synthetic-token\n")
    assert Token.read(path) == {:ok, "synthetic-token"}

    File.write!(path, "  \n")
    assert Token.read(path) == {:error, :empty_token}
    assert {:error, :empty_token} = Token.ensure(path)
  end

  test "valid?/2 compares tokens" do
    assert Token.valid?("abc", "abc")
    refute Token.valid?("abd", "abc")
    refute Token.valid?(nil, "abc")
  end
end

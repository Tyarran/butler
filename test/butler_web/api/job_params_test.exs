defmodule ButlerWeb.API.JobParamsTest do
  use ExUnit.Case, async: true

  alias ButlerWeb.API.JobParams

  defp mine, do: %{"source" => "/tmp/synthetic"}

  describe "validate/1 success" do
    test "builds the job attributes with defaults" do
      assert {:ok, %{kind: "mine", payload: payload, dedupe_key: nil, priority: 0}} =
               JobParams.validate(%{"kind" => "mine", "payload" => mine()})

      assert payload["source"] == "/tmp/synthetic"
    end

    test "keeps a dedupe key and a priority, null means default" do
      body = %{"kind" => "mine", "payload" => mine(), "dedupe_key" => "k", "priority" => -3}
      assert {:ok, %{dedupe_key: "k", priority: -3}} = JobParams.validate(body)

      body = %{"kind" => "mine", "payload" => mine(), "dedupe_key" => nil, "priority" => nil}
      assert {:ok, %{dedupe_key: nil, priority: 0}} = JobParams.validate(body)
    end
  end

  describe "validate/1 errors" do
    test "a body that is not an object is a 400" do
      assert {:error, 400, "invalid_payload", _message, nil} =
               JobParams.validate(%{"_json" => ["a"]})
    end

    test "an unknown key is a 400 naming the key" do
      assert {:error, 400, "invalid_payload", "Unknown key", "extra"} =
               JobParams.validate(%{"kind" => "mine", "extra" => 1})
    end

    test "palace_path wins over a bad kind" do
      assert {:error, 400, "invalid_payload", _message, "palace_path"} =
               JobParams.validate(%{"kind" => "nope", "palace_path" => "/x"})
    end

    test "an unknown kind wins over a bad priority" do
      assert {:error, 422, "unknown_kind", _message, "kind"} =
               JobParams.validate(%{"kind" => "nope", "priority" => "high"})
    end

    test "a UI-only kind is a 403" do
      assert {:error, 403, "kind_not_allowed", _message, "kind"} =
               JobParams.validate(%{"kind" => "repair"})
    end

    test "a missing or non-string kind is a 400" do
      assert {:error, 400, "invalid_payload", _message, "kind"} = JobParams.validate(%{})

      assert {:error, 400, "invalid_payload", _message, "kind"} =
               JobParams.validate(%{"kind" => 1})
    end

    test "a bad kind wins over a bad payload" do
      assert {:error, 422, "unknown_kind", _message, "kind"} =
               JobParams.validate(%{"kind" => "nope", "payload" => 5})
    end

    test "dedupe_key and priority are checked before the payload" do
      assert {:error, 400, _code, _message, "dedupe_key"} =
               JobParams.validate(%{"kind" => "mine", "dedupe_key" => "", "priority" => "x"})

      assert {:error, 400, _code, _message, "priority"} =
               JobParams.validate(%{"kind" => "mine", "priority" => 2_000_000, "payload" => 5})

      assert {:error, 400, _code, _message, "dedupe_key"} =
               JobParams.validate(%{"kind" => "mine", "dedupe_key" => 5})
    end

    test "dedupe_key longer than 200 characters is a 400" do
      assert {:error, 400, _code, _message, "dedupe_key"} =
               JobParams.validate(%{"kind" => "mine", "dedupe_key" => String.duplicate("a", 201)})
    end

    test "payload errors are prefixed with payload" do
      assert {:error, 400, "invalid_payload", _message, "payload.source"} =
               JobParams.validate(%{"kind" => "mine", "payload" => %{"source" => "relative"}})
    end
  end
end

**File:** `example_good_1736.md`

```elixir
defmodule HttpClient.Config do
  @moduledoc "Holds validated runtime configuration for a single HTTP client request."

  @enforce_keys [:base_url, :timeout_ms]
  defstruct [
    :base_url,
    timeout_ms: 5_000,
    headers: [],
    retry_count: 0,
    retry_delay_ms: 200
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          timeout_ms: pos_integer(),
          headers: [{String.t(), String.t()}],
          retry_count: non_neg_integer(),
          retry_delay_ms: non_neg_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) when is_list(opts) do
    with {:ok, base_url} <- require_string(opts, :base_url),
         {:ok, timeout_ms} <- optional_positive_integer(opts, :timeout_ms, 5_000),
         {:ok, retry_count} <- optional_non_neg_integer(opts, :retry_count, 0),
         {:ok, retry_delay_ms} <- optional_non_neg_integer(opts, :retry_delay_ms, 200) do
      {:ok, %__MODULE__{
        base_url: base_url,
        timeout_ms: timeout_ms,
        headers: Keyword.get(opts, :headers, []),
        retry_count: retry_count,
        retry_delay_ms: retry_delay_ms
      }}
    end
  end

  defp require_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_binary(val) and val != "" -> {:ok, val}
      {:ok, _} -> {:error, "#{key} must be a non-empty string"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp optional_positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      val when is_integer(val) and val > 0 -> {:ok, val}
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp optional_non_neg_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      val when is_integer(val) and val >= 0 -> {:ok, val}
      _ -> {:error, "#{key} must be a non-negative integer"}
    end
  end
end

defmodule HttpClient.Response do
  @moduledoc "Represents a completed HTTP response."

  @enforce_keys [:status, :headers, :body]
  defstruct [:status, :headers, :body]

  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }
end

defmodule HttpClient do
  @moduledoc """
  A thin, configurable HTTP client that accepts all options at call time.
  Supports retry with linear backoff and structured error responses.
  """

  alias HttpClient.{Config, Response}

  @type request_result :: {:ok, Response.t()} | {:error, term()}

  @spec get(String.t(), keyword()) :: request_result()
  def get(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, config} <- Config.new(opts) do
      execute(:get, path, nil, config, config.retry_count)
    end
  end

  @spec post(String.t(), map(), keyword()) :: request_result()
  def post(path, body, opts) when is_binary(path) and is_map(body) and is_list(opts) do
    with {:ok, config} <- Config.new(opts) do
      execute(:post, path, body, config, config.retry_count)
    end
  end

  @spec delete(String.t(), keyword()) :: request_result()
  def delete(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, config} <- Config.new(opts) do
      execute(:delete, path, nil, config, config.retry_count)
    end
  end

  defp execute(method, path, body, %Config{} = config, retries_left) do
    url = config.base_url <> path
    encoded_body = encode_body(body)

    case :httpc.request(method, build_request(url, config.headers, encoded_body),
           [{:timeout, config.timeout_ms}], []) do
      {:ok, {{_, status, _}, headers, resp_body}} ->
        {:ok, %Response{status: status, headers: headers, body: IO.iodata_to_binary(resp_body)}}

      {:error, reason} when retries_left > 0 ->
        Process.sleep(config.retry_delay_ms)
        execute(method, path, body, config, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_body(nil), do: nil
  defp encode_body(body), do: Jason.encode!(body)

  defp build_request(url, headers, nil) do
    {String.to_charlist(url), Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
  end

  defp build_request(url, headers, body) do
    {
      String.to_charlist(url),
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
      'application/json',
      String.to_charlist(body)
    }
  end
end
```

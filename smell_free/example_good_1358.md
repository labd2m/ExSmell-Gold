**File:** `example_good_1358.md`

```elixir
defmodule RateLimit.Bucket do
  @moduledoc """
  Tracks request counts within a sliding window for a single rate-limit key.
  """

  @enforce_keys [:key, :limit, :window_ms, :tokens, :window_start]
  defstruct [:key, :limit, :window_ms, :tokens, :window_start]

  @type t :: %__MODULE__{
          key: String.t(),
          limit: pos_integer(),
          window_ms: pos_integer(),
          tokens: non_neg_integer(),
          window_start: integer()
        }

  @spec new(String.t(), pos_integer(), pos_integer()) :: t()
  def new(key, limit, window_ms) do
    %__MODULE__{
      key: key,
      limit: limit,
      window_ms: window_ms,
      tokens: limit,
      window_start: System.monotonic_time(:millisecond)
    }
  end

  @spec consume(t()) :: {:allow, t()} | {:deny, t()}
  def consume(%__MODULE__{} = bucket) do
    now = System.monotonic_time(:millisecond)
    refreshed = maybe_refresh(bucket, now)

    if refreshed.tokens > 0 do
      {:allow, %{refreshed | tokens: refreshed.tokens - 1}}
    else
      {:deny, refreshed}
    end
  end

  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{} = bucket) do
    now = System.monotonic_time(:millisecond)
    maybe_refresh(bucket, now).tokens
  end

  defp maybe_refresh(%__MODULE__{window_start: ws, window_ms: wms} = bucket, now)
       when now - ws >= wms do
    %{bucket | tokens: bucket.limit, window_start: now}
  end

  defp maybe_refresh(bucket, _now), do: bucket
end

defmodule RateLimit.Store do
  @moduledoc """
  Manages a collection of rate-limit buckets using an Agent.
  Provides an explicit API for all bucket mutations and reads.
  """

  use Agent

  alias RateLimit.Bucket

  @type config :: %{limit: pos_integer(), window_ms: pos_integer()}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec check(String.t(), config()) :: :allow | :deny
  def check(key, %{limit: limit, window_ms: window_ms}) do
    Agent.get_and_update(__MODULE__, fn buckets ->
      bucket = Map.get_lazy(buckets, key, fn -> Bucket.new(key, limit, window_ms) end)

      case Bucket.consume(bucket) do
        {:allow, updated} -> {:allow, Map.put(buckets, key, updated)}
        {:deny, updated} -> {:deny, Map.put(buckets, key, updated)}
      end
    end)
  end

  @spec remaining_tokens(String.t(), config()) :: non_neg_integer()
  def remaining_tokens(key, %{limit: limit, window_ms: window_ms}) do
    Agent.get(__MODULE__, fn buckets ->
      bucket = Map.get_lazy(buckets, key, fn -> Bucket.new(key, limit, window_ms) end)
      Bucket.remaining(bucket)
    end)
  end

  @spec reset(String.t()) :: :ok
  def reset(key) do
    Agent.update(__MODULE__, &Map.delete(&1, key))
  end

  @spec flush_all() :: :ok
  def flush_all do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end
end

defmodule RateLimit.Plug do
  @moduledoc """
  A Plug that enforces per-IP rate limiting on incoming HTTP requests.
  Responds with 429 when the configured limit is exceeded.
  """

  import Plug.Conn

  alias RateLimit.Store

  @default_limit 100
  @default_window_ms :timer.minutes(1)

  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms)
    }
  end

  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%Plug.Conn{remote_ip: remote_ip} = conn, config) do
    key = format_ip(remote_ip)

    case Store.check(key, config) do
      :allow ->
        conn

      :deny ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(config.limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end

  defp format_ip(ip_tuple), do: ip_tuple |> Tuple.to_list() |> Enum.join(".")
end
```

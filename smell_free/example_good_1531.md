```elixir
defmodule Apigw.Plugs.RateLimiter do
  @moduledoc """
  Plug that enforces per-client request rate limits using a sliding window strategy.

  Configuration is passed at compile time via `plug/2` options, not through global
  application environment, so different pipelines can apply distinct limits.
  """

  @behaviour Plug

  import Plug.Conn

  alias Apigw.RateLimiter.{Counter, WindowConfig}

  @type options :: %{
          max_requests: pos_integer(),
          window_seconds: pos_integer(),
          key_fn: (Plug.Conn.t() -> String.t())
        }

  @impl Plug
  @spec init(keyword()) :: options()
  def init(opts) do
    %{
      max_requests: Keyword.fetch!(opts, :max_requests),
      window_seconds: Keyword.fetch!(opts, :window_seconds),
      key_fn: Keyword.get(opts, :key_fn, &default_key/1)
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def call(conn, %{max_requests: max, window_seconds: window, key_fn: key_fn}) do
    client_key = key_fn.(conn)
    config = WindowConfig.new(client_key, window)

    case Counter.increment(config) do
      {:ok, count} when count <= max ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(max))
        |> put_resp_header("x-ratelimit-remaining", to_string(max - count))

      {:ok, _count} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", to_string(window))
        |> send_resp(429, "rate limit exceeded")
        |> halt()

      {:error, _reason} ->
        conn
    end
  end

  defp default_key(%Plug.Conn{remote_ip: ip}) do
    ip |> :inet.ntoa() |> to_string()
  end
end

defmodule Apigw.RateLimiter.WindowConfig do
  @moduledoc false

  @enforce_keys [:key, :window_seconds]
  defstruct [:key, :window_seconds]

  @type t :: %__MODULE__{
          key: String.t(),
          window_seconds: pos_integer()
        }

  @spec new(String.t(), pos_integer()) :: t()
  def new(key, window_seconds) when is_binary(key) and is_integer(window_seconds) and window_seconds > 0 do
    %__MODULE__{key: key, window_seconds: window_seconds}
  end
end

defmodule Apigw.RateLimiter.Counter do
  @moduledoc """
  Stateful GenServer managing sliding-window request counts per client key.
  """

  use GenServer

  alias Apigw.RateLimiter.WindowConfig

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Increments the counter for a client window and returns the new total.
  """
  @spec increment(WindowConfig.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def increment(%WindowConfig{} = config) do
    GenServer.call(__MODULE__, {:increment, config})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:increment, %WindowConfig{key: key, window_seconds: window}}, _from, state) do
    now = System.system_time(:second)
    bucket = div(now, window)
    window_key = "#{key}:#{bucket}"

    new_count = Map.get(state, window_key, 0) + 1
    new_state = Map.put(state, window_key, new_count)

    {:reply, {:ok, new_count}, new_state}
  end
end
```

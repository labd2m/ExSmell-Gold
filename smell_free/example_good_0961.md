# File: `example_good_961.md`

```elixir
defmodule Auth.ApiThrottle do
  @moduledoc """
  GenServer implementing a sliding-window rate limiter for API key
  traffic, tracking request timestamps in a circular buffer per key.

  Unlike token-bucket limiters, the sliding window accurately counts
  requests in any rolling period rather than resetting on a fixed clock
  boundary. Expired request records are pruned lazily on each check.
  """

  use GenServer

  @default_limit 100
  @default_window_ms 60_000
  @sweep_interval_ms 120_000

  @type api_key :: String.t()

  @type throttle_config :: %{
          limit: pos_integer(),
          window_ms: pos_integer()
        }

  @type check_result :: :allow | {:deny, %{limit: pos_integer(), window_ms: pos_integer(), retry_after_ms: non_neg_integer()}}

  @type opts :: [
          default_limit: pos_integer(),
          default_window_ms: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks whether `api_key` may make another request.

  Returns `:allow` if within the window limit, or `{:deny, info}` with
  the limit, window size, and milliseconds until the oldest request expires.
  """
  @spec check(api_key()) :: check_result()
  def check(api_key) when is_binary(api_key) do
    GenServer.call(__MODULE__, {:check, api_key})
  end

  @doc """
  Configures a custom rate limit for a specific API key.
  """
  @spec configure(api_key(), pos_integer(), pos_integer()) :: :ok
  def configure(api_key, limit, window_ms)
      when is_binary(api_key) and is_integer(limit) and limit > 0 and
             is_integer(window_ms) and window_ms > 0 do
    GenServer.cast(__MODULE__, {:configure, api_key, limit, window_ms})
  end

  @doc """
  Resets the request history for an API key immediately.
  """
  @spec reset(api_key()) :: :ok
  def reset(api_key) when is_binary(api_key) do
    GenServer.cast(__MODULE__, {:reset, api_key})
  end

  @doc """
  Returns current request counts for all tracked API keys.
  """
  @spec usage_snapshot() :: %{api_key() => non_neg_integer()}
  def usage_snapshot do
    GenServer.call(__MODULE__, :usage_snapshot)
  end

  @impl GenServer
  def init(opts) do
    default_limit = Keyword.get(opts, :default_limit, @default_limit)
    default_window_ms = Keyword.get(opts, :default_window_ms, @default_window_ms)
    schedule_sweep()

    {:ok, %{
      windows: %{},
      configs: %{},
      default_limit: default_limit,
      default_window_ms: default_window_ms
    }}
  end

  @impl GenServer
  def handle_call({:check, api_key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    config = key_config(state, api_key)
    cutoff = now - config.window_ms

    history = Map.get(state.windows, api_key, [])
    valid_history = Enum.filter(history, &(&1 > cutoff))

    if length(valid_history) >= config.limit do
      oldest = Enum.min(valid_history)
      retry_after_ms = max(oldest + config.window_ms - now, 0)
      info = %{limit: config.limit, window_ms: config.window_ms, retry_after_ms: retry_after_ms}
      {:reply, {:deny, info}, state}
    else
      new_history = [now | valid_history]
      new_state = put_in(state, [:windows, api_key], new_history)
      {:reply, :allow, new_state}
    end
  end

  @impl GenServer
  def handle_call(:usage_snapshot, _from, state) do
    now = System.monotonic_time(:millisecond)

    snapshot =
      Map.new(state.windows, fn {key, history} ->
        config = key_config(state, key)
        cutoff = now - config.window_ms
        count = Enum.count(history, &(&1 > cutoff))
        {key, count}
      end)

    {:reply, snapshot, state}
  end

  @impl GenServer
  def handle_cast({:configure, api_key, limit, window_ms}, state) do
    config = %{limit: limit, window_ms: window_ms}
    {:noreply, put_in(state, [:configs, api_key], config)}
  end

  @impl GenServer
  def handle_cast({:reset, api_key}, state) do
    {:noreply, update_in(state, [:windows], &Map.delete(&1, api_key))}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    pruned_windows =
      Map.new(state.windows, fn {key, history} ->
        config = key_config(state, key)
        cutoff = now - config.window_ms
        {key, Enum.filter(history, &(&1 > cutoff))}
      end)
      |> Map.reject(fn {_key, history} -> history == [] end)

    schedule_sweep()
    {:noreply, %{state | windows: pruned_windows}}
  end

  defp key_config(state, api_key) do
    Map.get(state.configs, api_key, %{limit: state.default_limit, window_ms: state.default_window_ms})
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```

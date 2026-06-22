```elixir
defmodule ApiRateLimiter.Window do
  @moduledoc """
  Tracks request counts within a fixed time window for a single client key.
  """

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          window_start: integer(),
          window_ms: pos_integer(),
          limit: pos_integer()
        }

  defstruct [:window_start, :window_ms, :limit, count: 0]

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(limit, window_ms) do
    %__MODULE__{
      count: 0,
      window_start: System.monotonic_time(:millisecond),
      window_ms: window_ms,
      limit: limit
    }
  end

  @spec increment(t()) :: {t(), :allow | :deny}
  def increment(%__MODULE__{} = window) do
    now = System.monotonic_time(:millisecond)

    refreshed =
      if now - window.window_start >= window.window_ms do
        %{window | count: 0, window_start: now}
      else
        window
      end

    new_count = refreshed.count + 1
    decision = if new_count <= refreshed.limit, do: :allow, else: :deny
    {%{refreshed | count: new_count}, decision}
  end

  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{count: count, limit: limit}), do: max(limit - count, 0)

  @spec resets_in_ms(t()) :: non_neg_integer()
  def resets_in_ms(%__MODULE__{window_start: start, window_ms: ms}) do
    now = System.monotonic_time(:millisecond)
    max(ms - (now - start), 0)
  end
end

defmodule ApiRateLimiter do
  use GenServer

  alias ApiRateLimiter.Window

  @moduledoc """
  Plug-compatible API rate limiter backed by an in-process fixed-window counter.
  Limits, window durations, and key extraction are configurable per-deployment.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check(String.t(), keyword()) ::
          {:allow, %{remaining: non_neg_integer(), resets_in_ms: non_neg_integer()}}
          | {:deny, %{resets_in_ms: non_neg_integer()}}
  def check(key, opts \\ []) when is_binary(key) do
    GenServer.call(__MODULE__, {:check, key, opts})
  end

  @impl GenServer
  def init(opts) do
    default_limit = Keyword.get(opts, :limit, 100)
    default_window_ms = Keyword.get(opts, :window_ms, 60_000)
    {:ok, %{windows: %{}, default_limit: default_limit, default_window_ms: default_window_ms}}
  end

  @impl GenServer
  def handle_call({:check, key, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, state.default_limit)
    window_ms = Keyword.get(opts, :window_ms, state.default_window_ms)

    window =
      case Map.fetch(state.windows, key) do
        {:ok, existing} -> existing
        :error -> Window.new(limit, window_ms)
      end

    {updated_window, decision} = Window.increment(window)
    new_state = put_in(state.windows[key], updated_window)

    reply =
      case decision do
        :allow ->
          {:allow, %{remaining: Window.remaining(updated_window),
                     resets_in_ms: Window.resets_in_ms(updated_window)}}

        :deny ->
          {:deny, %{resets_in_ms: Window.resets_in_ms(updated_window)}}
      end

    {:reply, reply, new_state}
  end
end
```

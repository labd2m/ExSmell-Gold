# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `RateLimiter.start/1`
- **Affected function(s):** `RateLimiter.start/1`, `ApiGateway.check_rate/2`
- **Short explanation:** A per-client `GenServer` is spawned via `GenServer.start/3` to enforce rate limits. Because it is never supervised, a crash resets the token bucket silently — allowing a burst of requests through — with no way for the system to detect or recover from the failure.

```elixir
defmodule RateLimiter do
  use GenServer

  @moduledoc """
  Token-bucket rate limiter for a single client identifier (API key or IP).
  Refills tokens at a configurable rate and blocks when the bucket is empty.
  """

  defstruct [
    :client_id,
    :capacity,
    :refill_rate,
    :refill_interval_ms,
    :tokens,
    :last_refill
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because one rate-limiter process is created per
  # client via `GenServer.start/3` with no supervisor. If a rate-limiter process
  # crashes (e.g. due to a bad cast message), the token bucket is silently reset
  # to full capacity, allowing a client to bypass rate limiting. The application
  # has no mechanism to detect this breach or restart the limiter.
  def start(client_id, opts \\ []) do
    capacity = Keyword.get(opts, :capacity, 100)
    refill_rate = Keyword.get(opts, :refill_rate, 10)
    refill_interval_ms = Keyword.get(opts, :refill_interval_ms, 1_000)

    GenServer.start(
      __MODULE__,
      %{client_id: client_id, capacity: capacity, refill_rate: refill_rate, refill_interval_ms: refill_interval_ms},
      name: via(client_id)
    )
  end
  # VALIDATION: SMELL END

  def check_and_consume(client_id, tokens_needed \\ 1) do
    GenServer.call(via(client_id), {:consume, tokens_needed})
  end

  def available_tokens(client_id) do
    GenServer.call(via(client_id), :available)
  end

  def reset(client_id) do
    GenServer.cast(via(client_id), :reset)
  end

  defp via(id), do: {:via, Registry, {RateLimiterRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{client_id: id, capacity: cap, refill_rate: rr, refill_interval_ms: ri}) do
    state = %__MODULE__{
      client_id: id,
      capacity: cap,
      refill_rate: rr,
      refill_interval_ms: ri,
      tokens: cap,
      last_refill: System.monotonic_time(:millisecond)
    }

    schedule_refill(ri)
    {:ok, state}
  end

  @impl true
  def handle_call({:consume, needed}, _from, state) do
    state = maybe_refill(state)

    if state.tokens >= needed do
      {:reply, {:ok, state.tokens - needed}, %{state | tokens: state.tokens - needed}}
    else
      {:reply, {:error, :rate_limited, state.tokens}, state}
    end
  end

  def handle_call(:available, _from, state) do
    state = maybe_refill(state)
    {:reply, state.tokens, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    {:noreply, %{state | tokens: state.capacity}}
  end

  @impl true
  def handle_info(:refill, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_intervals = div(now - state.last_refill, state.refill_interval_ms)
    added = min(state.capacity, state.tokens + elapsed_intervals * state.refill_rate)

    schedule_refill(state.refill_interval_ms)
    {:noreply, %{state | tokens: added, last_refill: now}}
  end

  defp maybe_refill(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.last_refill >= state.refill_interval_ms do
      elapsed = div(now - state.last_refill, state.refill_interval_ms)
      added = min(state.capacity, state.tokens + elapsed * state.refill_rate)
      %{state | tokens: added, last_refill: now}
    else
      state
    end
  end

  defp schedule_refill(interval_ms) do
    Process.send_after(self(), :refill, interval_ms)
  end
end

defmodule ApiGateway do
  @moduledoc "Enforces per-client rate limits before routing API requests."

  def check_rate(client_id, tokens_needed \\ 1) do
    ensure_limiter_started(client_id)

    case RateLimiter.check_and_consume(client_id, tokens_needed) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited, _} -> {:error, :rate_limited}
    end
  end

  defp ensure_limiter_started(client_id) do
    case RateLimiter.start(client_id) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
```

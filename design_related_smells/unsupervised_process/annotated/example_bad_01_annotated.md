# Annotated Example 01 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `BillingRateLimiter.start/1`
- **Affected function(s):** `start/1`
- **Short explanation:** The GenServer is started with `GenServer.start/3` outside any supervision tree. Long-running billing rate-limiter processes accumulate without lifecycle management, making it impossible to restart them automatically on crash or shut them down cleanly.

```elixir
defmodule BillingRateLimiter do
  use GenServer

  @moduledoc """
  Per-customer rate limiter for billing API calls.
  Tracks request counts within a rolling time window to prevent
  customers from exceeding their contracted API usage tier.
  """

  @default_window_ms 60_000
  @default_max_requests 100

  defstruct [
    :customer_id,
    :max_requests,
    :window_ms,
    :requests,
    :window_start
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` launches a long-running
  # process completely outside any supervision tree. Each customer gets their own
  # process, so many such unsupervised processes can accumulate. If one crashes,
  # it is never restarted automatically, and there is no visibility into how many
  # are running or whether they are healthy.
  def start(customer_id) do
    initial_state = %__MODULE__{
      customer_id: customer_id,
      max_requests: @default_max_requests,
      window_ms: @default_window_ms,
      requests: 0,
      window_start: System.monotonic_time(:millisecond)
    }

    GenServer.start(__MODULE__, initial_state, name: via_name(customer_id))
  end
  # VALIDATION: SMELL END

  @doc """
  Returns {:ok, :allowed} if the customer is within their rate limit,
  or {:error, :rate_limited} with the milliseconds until the window resets.
  """
  def check_and_increment(customer_id) do
    case GenServer.whereis(via_name(customer_id)) do
      nil ->
        {:error, :limiter_not_started}

      _pid ->
        GenServer.call(via_name(customer_id), :check_and_increment)
    end
  end

  def current_usage(customer_id) do
    GenServer.call(via_name(customer_id), :current_usage)
  end

  def reset(customer_id) do
    GenServer.cast(via_name(customer_id), :reset)
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_window_reset(state.window_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:check_and_increment, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = maybe_reset_window(state, now)

    if state.requests < state.max_requests do
      new_state = %{state | requests: state.requests + 1}
      {:reply, {:ok, :allowed}, new_state}
    else
      ms_remaining = state.window_ms - (now - state.window_start)
      {:reply, {:error, {:rate_limited, ms_remaining}}, state}
    end
  end

  def handle_call(:current_usage, _from, state) do
    usage = %{
      customer_id: state.customer_id,
      requests: state.requests,
      max_requests: state.max_requests,
      window_ms: state.window_ms,
      window_start: state.window_start
    }

    {:reply, usage, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    {:noreply, %{state | requests: 0, window_start: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:window_reset, state) do
    schedule_window_reset(state.window_ms)
    {:noreply, %{state | requests: 0, window_start: System.monotonic_time(:millisecond)}}
  end

  defp maybe_reset_window(state, now) do
    if now - state.window_start >= state.window_ms do
      %{state | requests: 0, window_start: now}
    else
      state
    end
  end

  defp schedule_window_reset(window_ms) do
    Process.send_after(self(), :window_reset, window_ms)
  end

  defp via_name(customer_id) do
    {:via, Registry, {BillingRateLimiter.Registry, customer_id}}
  end
end
```

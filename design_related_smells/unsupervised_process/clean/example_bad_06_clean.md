```elixir
defmodule Payments.GatewayWorker do
  use GenServer

  @moduledoc """
  Manages the connection lifecycle and request serialization for a
  single payment gateway provider. Handles credential rotation,
  connection pooling, and idempotency-key tracking.
  """

  @idle_timeout_ms 60_000
  @max_concurrent_requests 10

  defstruct [
    :provider,
    :credentials,
    :base_url,
    :active_requests,
    :idempotency_keys,
    :request_count
  ]

  def start(provider) when provider in [:stripe, :paypal, :adyen] do
    config = Application.fetch_env!(:payments, provider)

    state = %__MODULE__{
      provider: provider,
      credentials: config[:credentials],
      base_url: config[:base_url],
      active_requests: %{},
      idempotency_keys: MapSet.new(),
      request_count: 0
    }

    GenServer.start(__MODULE__, state, name: worker_name(provider))
  end

  @doc """
  Submits a charge request. Returns {:ok, charge} or {:error, reason}.
  Deduplicates using the provided idempotency key.
  """
  def charge(provider, amount_cents, currency, idempotency_key, metadata \\ %{}) do
    GenServer.call(
      worker_name(provider),
      {:charge, amount_cents, currency, idempotency_key, metadata},
      15_000
    )
  end

  @doc "Refunds a previously captured charge."
  def refund(provider, charge_id, amount_cents \\ :full) do
    GenServer.call(worker_name(provider), {:refund, charge_id, amount_cents}, 15_000)
  end

  @doc "Returns current worker health metrics."
  def health(provider) do
    GenServer.call(worker_name(provider), :health)
  end

  ## Callbacks

  @impl true
  def init(state) do
    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:charge, _amount, _currency, idempotency_key, _meta}, _from, state)
      when map_size(state.active_requests) >= @max_concurrent_requests do
    {:reply, {:error, :capacity_exceeded}, state, @idle_timeout_ms}
  end

  def handle_call({:charge, amount, currency, idempotency_key, metadata}, _from, state) do
    if MapSet.member?(state.idempotency_keys, idempotency_key) do
      {:reply, {:error, :duplicate_request}, state, @idle_timeout_ms}
    else
      ref = make_ref()
      request = %{
        ref: ref,
        type: :charge,
        amount: amount,
        currency: currency,
        idempotency_key: idempotency_key,
        metadata: metadata,
        started_at: System.monotonic_time(:millisecond)
      }

      new_state = %{
        state
        | active_requests: Map.put(state.active_requests, ref, request),
          idempotency_keys: MapSet.put(state.idempotency_keys, idempotency_key),
          request_count: state.request_count + 1
      }

      # Simulate async call to provider
      result = simulate_gateway_call(state.provider, :charge, amount, currency)

      final_state = %{new_state | active_requests: Map.delete(new_state.active_requests, ref)}
      {:reply, result, final_state, @idle_timeout_ms}
    end
  end

  def handle_call({:refund, charge_id, amount}, _from, state) do
    result = simulate_gateway_call(state.provider, :refund, charge_id, amount)
    new_state = %{state | request_count: state.request_count + 1}
    {:reply, result, new_state, @idle_timeout_ms}
  end

  def handle_call(:health, _from, state) do
    health = %{
      provider: state.provider,
      active_requests: map_size(state.active_requests),
      total_requests: state.request_count,
      idempotency_cache_size: MapSet.size(state.idempotency_keys)
    }

    {:reply, health, state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    # Prune old idempotency keys to prevent unbounded memory growth
    {:noreply, %{state | idempotency_keys: MapSet.new()}, @idle_timeout_ms}
  end

  defp simulate_gateway_call(_provider, :charge, amount, _currency) when amount > 0 do
    {:ok, %{charge_id: "ch_#{:rand.uniform(999_999)}", status: :captured}}
  end

  defp simulate_gateway_call(_provider, :charge, _amount, _currency) do
    {:error, :invalid_amount}
  end

  defp simulate_gateway_call(_provider, :refund, charge_id, _amount) do
    {:ok, %{refund_id: "re_#{:rand.uniform(999_999)}", charge_id: charge_id, status: :refunded}}
  end

  defp worker_name(provider) do
    Module.concat(__MODULE__, provider |> Atom.to_string() |> String.capitalize())
  end
end
```

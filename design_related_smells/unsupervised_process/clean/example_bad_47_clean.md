```elixir
defmodule Billing.PaymentProcessor do
  @moduledoc """
  Handles asynchronous payment processing for individual orders.
  Each order gets its own worker process that coordinates charge attempts,
  retries, and webhook delivery.
  """

  use GenServer

  alias Billing.{Gateway, WebhookDispatcher, AuditLog}

  @max_retries 3
  @retry_delay_ms 2_000

  defstruct [
    :order_id,
    :customer_id,
    :amount_cents,
    :currency,
    :gateway_token,
    :retries,
    :status
  ]

  @doc """
  Starts a payment worker process for the given order outside any supervision tree.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  def start_worker(order_id) do
    GenServer.start(
      __MODULE__,
      %{order_id: order_id},
      name: via(order_id)
    )
  end

  @doc """
  Initiates a charge attempt for the given order.
  Starts a dedicated worker process and triggers the charge pipeline.
  """
  def charge(order_id, amount_cents, opts \\ []) do
    currency = Keyword.get(opts, :currency, "USD")
    customer_id = Keyword.get(opts, :customer_id)
    gateway_token = Keyword.get(opts, :gateway_token)

    case start_worker(order_id) do
      {:ok, _pid} ->
        GenServer.call(
          via(order_id),
          {:charge, amount_cents, currency, customer_id, gateway_token}
        )

      {:error, {:already_started, _pid}} ->
        {:error, :worker_already_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current state of a payment worker.
  """
  def status(order_id) do
    GenServer.call(via(order_id), :status)
  catch
    :exit, _ -> {:error, :not_found}
  end

  ## GenServer Callbacks

  @impl true
  def init(%{order_id: order_id}) do
    state = %__MODULE__{
      order_id: order_id,
      retries: 0,
      status: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:charge, amount_cents, currency, customer_id, gateway_token},
        _from,
        state
      ) do
    new_state = %{
      state
      | amount_cents: amount_cents,
        currency: currency,
        customer_id: customer_id,
        gateway_token: gateway_token,
        status: :processing
    }

    case attempt_charge(new_state) do
      {:ok, receipt} ->
        AuditLog.record(new_state.order_id, :charge_success, receipt)
        WebhookDispatcher.send_event(new_state.order_id, :payment_completed, receipt)
        {:reply, {:ok, receipt}, %{new_state | status: :completed}}

      {:error, reason} ->
        AuditLog.record(new_state.order_id, :charge_failed, reason)
        {:reply, {:error, reason}, %{new_state | status: :failed}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_info(:retry, state) when state.retries < @max_retries do
    case attempt_charge(state) do
      {:ok, receipt} ->
        AuditLog.record(state.order_id, :charge_success_after_retry, receipt)
        WebhookDispatcher.send_event(state.order_id, :payment_completed, receipt)
        {:noreply, %{state | status: :completed}}

      {:error, _reason} ->
        Process.send_after(self(), :retry, @retry_delay_ms)
        {:noreply, %{state | retries: state.retries + 1}}
    end
  end

  def handle_info(:retry, state) do
    AuditLog.record(state.order_id, :charge_exhausted_retries, %{retries: state.retries})
    WebhookDispatcher.send_event(state.order_id, :payment_failed, %{})
    {:noreply, %{state | status: :failed}}
  end

  ## Private Helpers

  defp attempt_charge(state) do
    Gateway.charge(%{
      token: state.gateway_token,
      amount: state.amount_cents,
      currency: state.currency,
      metadata: %{order_id: state.order_id, customer_id: state.customer_id}
    })
  end

  defp via(order_id) do
    {:via, Registry, {Billing.PaymentRegistry, order_id}}
  end
end
```

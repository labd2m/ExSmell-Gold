```elixir
defmodule MyApp.Subscriptions.BillingCycleServer do
  @moduledoc """
  A per-subscription GenServer that owns the billing cycle state for a
  single subscriber. Registered under the subscriber's ID via a
  `Registry`, it is started on demand by `MyApp.Subscriptions.Supervisor`
  and exits cleanly when the subscription is cancelled.

  Billing cycle advancement, proration calculation, and invoice creation
  are delegated to domain modules; this process is responsible only for
  coordinating timing and sequencing.
  """

  use GenServer, restart: :transient

  require Logger

  alias MyApp.Subscriptions.{BillingCycle, InvoiceFactory}
  alias MyApp.Mailer

  @check_interval_ms 60_000

  @type state :: %{
          subscription_id: String.t(),
          cycle: BillingCycle.t()
        }

  @doc "Starts a billing cycle server for the given subscription."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    subscription_id = Keyword.fetch!(opts, :subscription_id)
    GenServer.start_link(__MODULE__, opts, name: via(subscription_id))
  end

  @doc "Returns the current billing cycle snapshot for a subscription."
  @spec current_cycle(String.t()) :: {:ok, BillingCycle.t()} | {:error, :not_running}
  def current_cycle(subscription_id) when is_binary(subscription_id) do
    case Registry.lookup(MyApp.Subscriptions.Registry, subscription_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :current_cycle)}
      [] -> {:error, :not_running}
    end
  end

  @doc "Gracefully stops the server for the given subscription."
  @spec stop(String.t()) :: :ok
  def stop(subscription_id) when is_binary(subscription_id) do
    case Registry.lookup(MyApp.Subscriptions.Registry, subscription_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  @impl GenServer
  def init(opts) do
    subscription_id = Keyword.fetch!(opts, :subscription_id)

    case BillingCycle.load(subscription_id) do
      {:ok, cycle} ->
        schedule_check()
        {:ok, %{subscription_id: subscription_id, cycle: cycle}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:current_cycle, _from, state) do
    {:reply, state.cycle, state}
  end

  @impl GenServer
  def handle_info(:check_cycle, state) do
    new_state =
      if BillingCycle.due?(state.cycle) do
        advance_cycle(state)
      else
        state
      end

    schedule_check()
    {:noreply, new_state}
  end

  @spec advance_cycle(state()) :: state()
  defp advance_cycle(state) do
    with {:ok, invoice} <- InvoiceFactory.create(state.subscription_id, state.cycle),
         {:ok, new_cycle} <- BillingCycle.advance(state.cycle) do
      deliver_invoice_email(state.subscription_id, invoice)

      Logger.info("billing_cycle_advanced",
        subscription_id: state.subscription_id,
        invoice_id: invoice.id
      )

      %{state | cycle: new_cycle}
    else
      {:error, reason} ->
        Logger.error("billing_cycle_advance_failed",
          subscription_id: state.subscription_id,
          reason: inspect(reason)
        )

        state
    end
  end

  @spec deliver_invoice_email(String.t(), map()) :: :ok
  defp deliver_invoice_email(subscription_id, invoice) do
    case Mailer.deliver_invoice(subscription_id, invoice) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("invoice_email_failed", reason: inspect(reason))
    end
  end

  @spec schedule_check() :: reference()
  defp schedule_check, do: Process.send_after(self(), :check_cycle, @check_interval_ms)

  @spec via(String.t()) :: {:via, Registry, {MyApp.Subscriptions.Registry, String.t()}}
  defp via(id), do: {:via, Registry, {MyApp.Subscriptions.Registry, id}}
end
```

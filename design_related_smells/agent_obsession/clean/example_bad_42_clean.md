```elixir
defmodule PaymentStateAgent do
  @moduledoc "Shared Agent for payment transaction state."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          transactions: %{},
          refunds: [],
          daily_totals: %{}
        }
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

defmodule PaymentInitiator do
  @moduledoc "Creates pending payment transactions."

  require Logger

  @supported_methods [:card, :bank_transfer, :wallet, :crypto]

  def initiate(agent, %{
        amount: amount,
        currency: currency,
        method: method,
        customer_id: customer_id
      } = params)
      when method in @supported_methods and amount > 0 do
    txn_id = "txn_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

    transaction = %{
      id: txn_id,
      amount: amount,
      currency: currency,
      method: method,
      customer_id: customer_id,
      status: :pending,
      metadata: Map.get(params, :metadata, %{}),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      %{state | transactions: Map.put(state.transactions, txn_id, transaction)}
    end)

    Logger.info("Initiated #{method} payment #{txn_id} for #{amount} #{currency}")
    {:ok, txn_id}
  end

  def initiate(_agent, params), do: {:error, {:invalid_params, params}}
end
defmodule PaymentConfirmer do
  @moduledoc "Confirms pending transactions after gateway callback."

  require Logger

  def confirm(agent, txn_id, gateway_ref) do
    case Agent.get(agent, fn state -> Map.get(state.transactions, txn_id) end) do
      nil ->
        {:error, :not_found}

      %{status: :confirmed} ->
        {:error, :already_confirmed}

      %{status: :pending} = txn ->
        today = Date.utc_today() |> Date.to_string()

        Agent.update(agent, fn state ->
          updated_txn = %{txn | status: :confirmed, gateway_ref: gateway_ref, updated_at: DateTime.utc_now()}

          new_daily =
            Map.update(
              state.daily_totals,
              today,
              txn.amount,
              &(&1 + txn.amount)
            )

          %{
            state
            | transactions: Map.put(state.transactions, txn_id, updated_txn),
              daily_totals: new_daily
          }
        end)

        Logger.info("Confirmed payment #{txn_id} via gateway ref #{gateway_ref}")
        :ok

      %{status: status} ->
        {:error, {:invalid_status_transition, status}}
    end
  end
end
defmodule RefundProcessor do
  @moduledoc "Processes full and partial refunds against confirmed transactions."

  require Logger

  def issue_refund(agent, txn_id, refund_amount) do
    case Agent.get(agent, fn state -> Map.get(state.transactions, txn_id) end) do
      nil ->
        {:error, :transaction_not_found}

      %{status: :confirmed, amount: original} when refund_amount > original ->
        {:error, :refund_exceeds_original}

      %{status: :confirmed, amount: original} = txn ->
        refund_id = "ref_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
        is_full = refund_amount == original

        Agent.update(agent, fn state ->
          refund = %{
            id: refund_id,
            txn_id: txn_id,
            amount: refund_amount,
            full: is_full,
            issued_at: DateTime.utc_now()
          }

          new_status = if is_full, do: :refunded, else: :partially_refunded
          updated_txn = %{txn | status: new_status, updated_at: DateTime.utc_now()}

          %{
            state
            | transactions: Map.put(state.transactions, txn_id, updated_txn),
              refunds: [refund | state.refunds]
          }
        end)

        Logger.info("Issued refund #{refund_id} of #{refund_amount} for #{txn_id}")
        {:ok, refund_id}

      %{status: status} ->
        {:error, {:non_refundable_status, status}}
    end
  end
end
defmodule PaymentLedger do
  @moduledoc "Query interface for payment totals and transaction history."

  def balance(agent, customer_id) do
    Agent.get(agent, fn state ->
      state.transactions
      |> Map.values()
      |> Enum.filter(&(&1.customer_id == customer_id and &1.status == :confirmed))
      |> Enum.reduce(0, &(&1.amount + &2))
    end)
  end

  def daily_revenue(agent, date_str) do
    Agent.get(agent, fn state -> Map.get(state.daily_totals, date_str, 0) end)
  end

  def recent_transactions(agent, n \\ 20) do
    Agent.get(agent, fn state ->
      state.transactions
      |> Map.values()
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.take(n)
    end)
  end
end
```

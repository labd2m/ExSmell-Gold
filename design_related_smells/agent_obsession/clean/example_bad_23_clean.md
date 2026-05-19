```elixir
defmodule PaymentAgentStore do
  @moduledoc "Starts the shared payments agent."

  def start do
    {:ok, pid} = Agent.start_link(fn ->
      %{transactions: [], refunds: [], balance: 0.0, reconciled_through: nil}
    end)
    pid
  end
end

defmodule PaymentProcessor do
  @moduledoc """
  Processes charge transactions and updates the payment agent.
  """

  @supported_currencies ~w(USD EUR GBP BRL)

  def charge(pid, amount, currency, opts \\ []) when is_float(amount) and amount > 0 do
    if currency not in @supported_currencies do
      {:error, :unsupported_currency}
    else
      tx = %{
        id: generate_tx_id(),
        type: :charge,
        amount: amount,
        currency: currency,
        description: Keyword.get(opts, :description, ""),
        customer_id: Keyword.fetch!(opts, :customer_id),
        status: :completed,
        inserted_at: DateTime.utc_now()
      }

      Agent.update(pid, fn state ->
        %{state |
          transactions: [tx | state.transactions],
          balance: state.balance + amount
        }
      end)

      {:ok, tx}
    end
  end

  def transaction_count(pid) do
    Agent.get(pid, fn state -> length(state.transactions) end)
  end

  defp generate_tx_id do
    "tx_" <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end
end

defmodule PaymentRefund do
  @moduledoc """
  Issues refunds against existing charges in the payment agent.
  """

  def issue(pid, original_tx_id, amount, reason) do
    original =
      Agent.get(pid, fn state ->
        Enum.find(state.transactions, fn tx ->
          tx.id == original_tx_id and tx.type == :charge
        end)
      end)

    case original do
      nil ->
        {:error, :charge_not_found}

      tx when amount > tx.amount ->
        {:error, :refund_exceeds_charge}

      tx ->
        refund = %{
          id: generate_refund_id(),
          original_tx_id: original_tx_id,
          customer_id: tx.customer_id,
          amount: amount,
          reason: reason,
          status: :completed,
          inserted_at: DateTime.utc_now()
        }

        Agent.update(pid, fn state ->
          %{state |
            refunds: [refund | state.refunds],
            balance: state.balance - amount
          }
        end)

        {:ok, refund}
    end
  end

  defp generate_refund_id do
    "ref_" <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end
end

defmodule PaymentReconciler do
  @moduledoc """
  Reconciles payment transactions up to a given date.
  """

  def reconcile(pid, up_to \\ DateTime.utc_now()) do
    state = Agent.get(pid, fn s -> s end)

    unreconciled_charges =
      Enum.filter(state.transactions, fn tx ->
        tx.type == :charge and DateTime.compare(tx.inserted_at, up_to) == :lt
      end)

    unreconciled_refunds =
      Enum.filter(state.refunds, fn r ->
        DateTime.compare(r.inserted_at, up_to) == :lt
      end)

    net =
      Enum.reduce(unreconciled_charges, 0.0, fn tx, acc -> acc + tx.amount end) -
        Enum.reduce(unreconciled_refunds, 0.0, fn r, acc -> acc + r.amount end)

    Agent.update(pid, fn s -> %{s | reconciled_through: up_to} end)

    {:ok, %{net: net, charges: length(unreconciled_charges), refunds: length(unreconciled_refunds)}}
  end
end

defmodule PaymentLedger do
  @moduledoc """
  Generates a statement for a customer from the payment agent.
  """

  def statement(pid, customer_id) do
    state = Agent.get(pid, fn s -> s end)

    charges =
      Enum.filter(state.transactions, fn tx ->
        tx.customer_id == customer_id and tx.type == :charge
      end)

    refunds =
      Enum.filter(state.refunds, fn r -> r.customer_id == customer_id end)

    total_charged = Enum.reduce(charges, 0.0, fn tx, acc -> acc + tx.amount end)
    total_refunded = Enum.reduce(refunds, 0.0, fn r, acc -> acc + r.amount end)

    %{
      customer_id: customer_id,
      charges: charges,
      refunds: refunds,
      total_charged: Float.round(total_charged, 2),
      total_refunded: Float.round(total_refunded, 2),
      net_billed: Float.round(total_charged - total_refunded, 2),
      generated_at: DateTime.utc_now()
    }
  end
end
```

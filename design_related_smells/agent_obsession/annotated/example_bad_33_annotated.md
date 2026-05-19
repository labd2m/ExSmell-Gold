# Code Smell: Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `PaymentGateway`, `PaymentReconciler`, `PaymentHistory`, and `PaymentFraudCheck`
- **Affected functions:** `PaymentGateway.record_transaction/2`, `PaymentReconciler.settle/2`, `PaymentHistory.transactions_for/2`, `PaymentFraudCheck.flag_suspicious/2`
- **Short explanation:** Payment transaction state stored in an Agent is accessed from four separate modules, each directly encoding the internal map structure. No single module acts as the owner or gatekeeper of the agent's state.

---

```elixir
defmodule Payments.PaymentGateway do
  @moduledoc """
  Records incoming payment transactions into shared state.
  """

  def start_link() do
    Agent.start_link(fn ->
      %{transactions: [], settled: [], flagged: []}
    end, name: __MODULE__)
  end

  def record_transaction(pid, transaction) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because PaymentGateway directly calls Agent.update/2
    # to store transactions. The responsibility for agent state management is not
    # encapsulated in one place.
    Agent.update(pid, fn state ->
      entry = Map.merge(transaction, %{
        id: :crypto.strong_rand_bytes(8) |> Base.encode16(),
        recorded_at: DateTime.utc_now(),
        status: :pending
      })
      %{state | transactions: [entry | state.transactions]}
    end)
    # VALIDATION: SMELL END
  end

  def get_transaction(pid, tx_id) do
    Agent.get(pid, fn state ->
      Enum.find(state.transactions, &(&1.id == tx_id))
    end)
  end

  def pending_count(pid) do
    Agent.get(pid, fn state ->
      Enum.count(state.transactions, &(&1.status == :pending))
    end)
  end
end

defmodule Payments.PaymentReconciler do
  @moduledoc """
  Settles pending transactions and updates their status.
  """

  def settle(pid, tx_id) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because PaymentReconciler directly calls Agent.update/2
    # to move a transaction to the settled list, independently from the module that
    # recorded it in the first place.
    Agent.update(pid, fn state ->
      {to_settle, remaining} =
        Enum.split_with(state.transactions, fn tx -> tx.id == tx_id end)

      settled_entries =
        Enum.map(to_settle, &Map.merge(&1, %{status: :settled, settled_at: DateTime.utc_now()}))

      %{state | transactions: remaining, settled: state.settled ++ settled_entries}
    end)
    # VALIDATION: SMELL END
  end

  def settle_all_pending(pid) do
    Agent.update(pid, fn state ->
      {pending, others} = Enum.split_with(state.transactions, &(&1.status == :pending))
      now = DateTime.utc_now()
      newly_settled = Enum.map(pending, &Map.merge(&1, %{status: :settled, settled_at: now}))
      %{state | transactions: others, settled: state.settled ++ newly_settled}
    end)
  end
end

defmodule Payments.PaymentHistory do
  @moduledoc """
  Provides query access to historical payment records.
  """

  def transactions_for(pid, account_id) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because PaymentHistory directly reads Agent state,
    # introducing a third module that knows the shape of the transactions and settled lists.
    Agent.get(pid, fn state ->
      all = state.transactions ++ state.settled ++ state.flagged
      Enum.filter(all, &(&1.account_id == account_id))
    end)
    # VALIDATION: SMELL END
  end

  def total_volume(pid) do
    Agent.get(pid, fn state ->
      all = state.transactions ++ state.settled
      Enum.reduce(all, Decimal.new(0), fn tx, acc ->
        Decimal.add(acc, tx.amount)
      end)
    end)
  end
end

defmodule Payments.PaymentFraudCheck do
  @moduledoc """
  Flags suspicious transactions based on heuristics.
  """

  def flag_suspicious(pid, tx_id) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because PaymentFraudCheck directly calls Agent.update/2
    # to move a transaction to the flagged list, becoming a fourth independent module
    # directly manipulating the shared agent state.
    Agent.update(pid, fn state ->
      {to_flag, remaining} =
        Enum.split_with(state.transactions, fn tx -> tx.id == tx_id end)

      flagged_entries =
        Enum.map(to_flag, &Map.merge(&1, %{status: :flagged, flagged_at: DateTime.utc_now()}))

      %{state | transactions: remaining, flagged: state.flagged ++ flagged_entries}
    end)
    # VALIDATION: SMELL END
  end

  def high_value_pending(pid, threshold) do
    Agent.get(pid, fn state ->
      Enum.filter(state.transactions, fn tx ->
        tx.status == :pending and Decimal.compare(tx.amount, threshold) == :gt
      end)
    end)
  end
end
```

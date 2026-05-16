# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `AccountTransferService.transfer/4`, where `amount` is used in subtraction and addition against account balances
- **Affected function(s):** `transfer/4`, `apply_debit/2`, `apply_credit/2`
- **Short explanation:** The `amount` parameter is passed to `apply_debit/2` and `apply_credit/2`, which perform arithmetic directly against account balance fields, without any upfront check that `amount` is a numeric type. If a caller passes a string, an atom, or a `Decimal` struct while the balances are plain floats, an `ArithmeticError` (or similar) is raised inside the private helper functions, far from the `transfer/4` entry point where the invalid data was accepted.

```elixir
defmodule MyApp.Banking.AccountTransferService do
  @moduledoc """
  Executes fund transfers between internal accounts with double-entry bookkeeping,
  balance validation, daily limit enforcement, and transaction journal recording.
  """

  require Logger

  alias MyApp.Banking.{AccountStore, TransactionJournal, DailyLimitTracker, ComplianceChecker}

  @minimum_transfer_amount 0.01
  @rounding_precision 2
  @journal_entry_version 2

  @type transfer_opts :: [
          reference: String.t(),
          description: String.t(),
          notify: boolean(),
          scheduled_at: DateTime.t() | nil
        ]

  @spec transfer(String.t(), String.t(), term(), String.t(), transfer_opts()) ::
          {:ok, map()} | {:error, atom()}
  def transfer(from_account_id, to_account_id, amount, currency, opts \\ []) do
    reference = Keyword.get(opts, :reference, generate_reference())
    description = Keyword.get(opts, :description, "Transfer")
    notify = Keyword.get(opts, :notify, true)

    with {:ok, from_account} <- AccountStore.fetch(from_account_id),
         {:ok, to_account} <- AccountStore.fetch(to_account_id),
         :ok <- check_same_currency(from_account, to_account, currency),
         :ok <- check_sufficient_balance(from_account, amount),
         :ok <- check_daily_limit(from_account_id, amount),
         :ok <- ComplianceChecker.screen_transfer(from_account_id, to_account_id, amount) do

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `amount` is passed to `apply_debit/2`
      # VALIDATION: and `apply_credit/2` where it is used in arithmetic against
      # VALIDATION: `account.balance` without any type validation at the boundary.
      # VALIDATION: If a caller passes a string like "150.00" or a Decimal struct
      # VALIDATION: while balances are floats, the subtraction in `apply_debit/2`
      # VALIDATION: raises an ArithmeticError deep in Kernel arithmetic operators,
      # VALIDATION: with no indication that the bad data entered at `transfer/4`.
      updated_from = apply_debit(from_account, amount)
      updated_to = apply_credit(to_account, amount)
      # VALIDATION: SMELL END

      journal_entry = %{
        id: Ecto.UUID.generate(),
        reference: reference,
        description: description,
        from_account_id: from_account_id,
        to_account_id: to_account_id,
        amount: amount,
        currency: currency,
        from_balance_before: from_account.balance,
        from_balance_after: updated_from.balance,
        to_balance_before: to_account.balance,
        to_balance_after: updated_to.balance,
        version: @journal_entry_version,
        created_at: DateTime.utc_now()
      }

      with {:ok, _} <- AccountStore.save(updated_from),
           {:ok, _} <- AccountStore.save(updated_to),
           {:ok, entry} <- TransactionJournal.record(journal_entry),
           :ok <- DailyLimitTracker.increment(from_account_id, amount) do
        Logger.info(
          "Transfer completed: #{from_account_id} -> #{to_account_id} " <>
            "amount=#{amount} #{currency} ref=#{reference}"
        )

        maybe_send_notifications(from_account, to_account, amount, currency, notify)
        {:ok, entry}
      end
    end
  end

  @spec balance(String.t()) :: {:ok, map()} | {:error, atom()}
  def balance(account_id) do
    with {:ok, account} <- AccountStore.fetch(account_id) do
      {:ok,
       %{
         account_id: account_id,
         balance: account.balance,
         currency: account.currency,
         as_of: DateTime.utc_now()
       }}
    end
  end

  @spec transfer_history(String.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def transfer_history(account_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    TransactionJournal.list_for_account(account_id, page, per_page)
  end

  @spec daily_limit_remaining(String.t()) :: {:ok, number()} | {:error, atom()}
  def daily_limit_remaining(account_id) do
    with {:ok, account} <- AccountStore.fetch(account_id),
         {:ok, used_today} <- DailyLimitTracker.total_today(account_id) do
      remaining = account.daily_transfer_limit - used_today
      {:ok, max(0, remaining)}
    end
  end

  # Private helpers

  defp apply_debit(account, amount) do
    new_balance = Float.round(account.balance - amount, @rounding_precision)
    %{account | balance: new_balance}
  end

  defp apply_credit(account, amount) do
    new_balance = Float.round(account.balance + amount, @rounding_precision)
    %{account | balance: new_balance}
  end

  defp check_same_currency(%{currency: c}, %{currency: c}, c), do: :ok
  defp check_same_currency(_, _, _), do: {:error, :currency_mismatch}

  defp check_sufficient_balance(account, amount) do
    if account.balance >= amount + @minimum_transfer_amount do
      :ok
    else
      {:error, :insufficient_balance}
    end
  end

  defp check_daily_limit(account_id, amount) do
    case DailyLimitTracker.would_exceed?(account_id, amount) do
      false -> :ok
      true -> {:error, :daily_limit_exceeded}
    end
  end

  defp maybe_send_notifications(from, to, amount, currency, true) do
    Logger.info(
      "Notifications queued: from=#{from.id} to=#{to.id} amount=#{amount} #{currency}"
    )
  end

  defp maybe_send_notifications(_, _, _, _, false), do: :ok

  defp generate_reference do
    :crypto.strong_rand_bytes(10) |> Base.encode16(case: :upper)
  end
end
```

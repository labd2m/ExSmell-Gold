```elixir
defmodule MyApp.BillingAgent do
  @moduledoc """
  Manages billing state and charge processing for subscription accounts.
  """

  use Agent

  alias MyApp.{Mailer, PaymentGateway, Repo}
  alias MyApp.Billing.{Invoice, Receipt}

  @max_retries 3
  @retry_delay_ms 2_000

  def start_link(initial_state \\ %{}) do
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  def get_pending_invoices do
    Agent.get(__MODULE__, fn state -> Map.get(state, :pending_invoices, []) end)
  end

  def put_pending_invoices(invoices) do
    Agent.update(__MODULE__, fn state -> Map.put(state, :pending_invoices, invoices) end)
  end

  def get_failed_charges do
    Agent.get(__MODULE__, fn state -> Map.get(state, :failed_charges, []) end)
  end


  def process_charge(invoice_id, amount) do
    Agent.get_and_update(__MODULE__, fn state ->
      case PaymentGateway.charge(invoice_id, amount) do
        {:ok, transaction} ->
          receipt = %Receipt{
            invoice_id: invoice_id,
            amount: amount,
            transaction_id: transaction.id,
            charged_at: DateTime.utc_now()
          }

          updated_state =
            state
            |> Map.update(:processed_charges, [receipt], &[receipt | &1])
            |> Map.update(:pending_invoices, [], fn pending ->
              Enum.reject(pending, &(&1.id == invoice_id))
            end)

          {{:ok, receipt}, updated_state}

        {:error, reason} ->
          failed_entry = %{invoice_id: invoice_id, reason: reason, attempt: 1}

          updated_state =
            Map.update(state, :failed_charges, [failed_entry], &[failed_entry | &1])

          {{:error, reason}, updated_state}
      end
    end)
  end

  def retry_failed_charges(account_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      failed = Map.get(state, :failed_charges, [])

      {retried, still_failing} =
        failed
        |> Enum.filter(&(&1.account_id == account_id))
        |> Enum.reduce({[], []}, fn entry, {ok_acc, fail_acc} ->
          if entry.attempt < @max_retries do
            Process.sleep(@retry_delay_ms)

            case PaymentGateway.charge(entry.invoice_id, entry.amount) do
              {:ok, transaction} ->
                receipt = %Receipt{
                  invoice_id: entry.invoice_id,
                  amount: entry.amount,
                  transaction_id: transaction.id,
                  charged_at: DateTime.utc_now()
                }
                {[receipt | ok_acc], fail_acc}

              {:error, _reason} ->
                updated = Map.update(entry, :attempt, 1, &(&1 + 1))
                {ok_acc, [updated | fail_acc]}
            end
          else
            {ok_acc, [entry | fail_acc]}
          end
        end)

      remaining_failed =
        Enum.reject(failed, &(&1.account_id == account_id)) ++ still_failing

      updated_state =
        state
        |> Map.put(:failed_charges, remaining_failed)
        |> Map.update(:processed_charges, retried, &(retried ++ &1))

      {{:ok, length(retried)}, updated_state}
    end)
  end

  def send_receipt(invoice_id, email) do
    Agent.get(__MODULE__, fn state ->
      processed = Map.get(state, :processed_charges, [])

      case Enum.find(processed, &(&1.invoice_id == invoice_id)) do
        nil ->
          {:error, :not_found}

        receipt ->
          Mailer.deliver_receipt(email, receipt)
      end
    end)
  end


  def summarise(account_id) do
    Agent.get(__MODULE__, fn state ->
      processed = Map.get(state, :processed_charges, [])
      failed = Map.get(state, :failed_charges, [])

      %{
        total_processed: length(processed),
        total_failed: length(failed),
        account_id: account_id
      }
    end)
  end
end
```

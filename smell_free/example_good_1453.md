```elixir
defmodule Invoicing.PaymentProcessor do
  @moduledoc """
  Handles payment authorization and capture lifecycle for invoice settlements.

  Coordinates with external payment gateways while maintaining an auditable
  transaction record. All gateway interactions return normalized result tuples.
  """

  alias Invoicing.{Invoice, Transaction, Gateway}
  alias Invoicing.Repo

  @type payment_params :: %{
          invoice_id: Ecto.UUID.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          payment_method_token: String.t()
        }

  @type charge_result ::
          {:ok, Transaction.t()}
          | {:error, :invoice_not_found}
          | {:error, :already_settled}
          | {:error, :gateway_declined}
          | {:error, :invalid_currency}

  @supported_currencies ~w(USD EUR GBP BRL)

  @doc """
  Authorizes and captures a payment for a given invoice.

  Returns `{:ok, transaction}` on success or a tagged error tuple describing
  the specific failure reason.
  """
  @spec process_charge(payment_params()) :: charge_result()
  def process_charge(%{currency: currency} = params)
      when currency not in @supported_currencies do
    {:error, :invalid_currency}
  end

  def process_charge(%{invoice_id: invoice_id} = params) do
    with {:ok, invoice} <- fetch_open_invoice(invoice_id),
         {:ok, auth_code} <- Gateway.authorize(params),
         {:ok, transaction} <- capture_and_record(invoice, auth_code, params) do
      {:ok, transaction}
    end
  end

  @doc """
  Refunds a previously captured transaction up to its original charged amount.
  """
  @spec refund_transaction(Ecto.UUID.t(), pos_integer()) ::
          {:ok, Transaction.t()} | {:error, :transaction_not_found} | {:error, :refund_exceeds_original}
  def refund_transaction(transaction_id, refund_cents) do
    with {:ok, transaction} <- fetch_captured_transaction(transaction_id),
         :ok <- validate_refund_amount(transaction, refund_cents),
         {:ok, _ref} <- Gateway.refund(transaction.gateway_ref, refund_cents) do
      record_refund(transaction, refund_cents)
    end
  end

  # Private helpers

  defp fetch_open_invoice(invoice_id) do
    case Repo.get(Invoice, invoice_id) do
      nil -> {:error, :invoice_not_found}
      %Invoice{status: :settled} -> {:error, :already_settled}
      invoice -> {:ok, invoice}
    end
  end

  defp fetch_captured_transaction(transaction_id) do
    case Repo.get(Transaction, transaction_id) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
    end
  end

  defp validate_refund_amount(%Transaction{amount_cents: original}, refund_cents)
       when refund_cents > original do
    {:error, :refund_exceeds_original}
  end

  defp validate_refund_amount(_transaction, _refund_cents), do: :ok

  defp capture_and_record(invoice, auth_code, %{amount_cents: amount, currency: currency}) do
    Repo.transaction(fn ->
      with {:ok, gateway_ref} <- Gateway.capture(auth_code),
           {:ok, transaction} <-
             insert_transaction(invoice.id, gateway_ref, amount, currency),
           {:ok, _invoice} <- mark_invoice_settled(invoice) do
        transaction
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_transaction(invoice_id, gateway_ref, amount_cents, currency) do
    %Transaction{}
    |> Transaction.changeset(%{
      invoice_id: invoice_id,
      gateway_ref: gateway_ref,
      amount_cents: amount_cents,
      currency: currency,
      status: :captured
    })
    |> Repo.insert()
  end

  defp mark_invoice_settled(invoice) do
    invoice
    |> Invoice.changeset(%{status: :settled, settled_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp record_refund(transaction, refund_cents) do
    transaction
    |> Transaction.changeset(%{
      status: :refunded,
      refunded_cents: refund_cents,
      refunded_at: DateTime.utc_now()
    })
    |> Repo.update()
  end
end
```

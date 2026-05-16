```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles end-to-end processing of customer invoices:
  fetching, validation, tax computation, and persistence.
  """

  alias Billing.{Invoice, TaxEngine, Repo, Mailer}
  require Logger

  @max_invoice_amount Decimal.new("999_999.99")

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Processes a raw invoice payload for the given `customer_id`.

  Returns `{:ok, invoice}` on success or a tagged error tuple describing
  the failure stage.
  """
  @spec process_invoice(String.t(), map()) ::
          {:ok, Invoice.t()}
          | {:error, :customer_not_found}
          | {:error, :invalid_payload}
          | {:error, :tax_computation_failed}
          | {:error, :persistence_failed}
  def process_invoice(customer_id, raw_payload) do
    with {:ok, customer}  <- fetch_customer(customer_id),
         {:ok, payload}   <- validate_payload(raw_payload),
         {:ok, tax_lines} <- TaxEngine.compute(customer, payload),
         {:ok, invoice}   <- persist_invoice(customer, payload, tax_lines) do
      Logger.info("Invoice #{invoice.id} created for customer #{customer_id}")
      notify_customer(customer, invoice)
      {:ok, invoice}
    else
      {:error, :not_found} ->
        Logger.warn("Customer #{customer_id} not found")
        {:error, :customer_not_found}

      {:error, :validation, reason} ->
        Logger.warn("Payload validation failed: #{inspect(reason)}")
        {:error, :invalid_payload}

      {:error, :tax, detail} ->
        Logger.error("Tax computation error: #{inspect(detail)}")
        {:error, :tax_computation_failed}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Persistence failed: #{inspect(changeset.errors)}")
        {:error, :persistence_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_customer(customer_id) do
    case Repo.get_by(Billing.Customer, external_id: customer_id) do
      nil      -> {:error, :not_found}
      customer -> {:ok, customer}
    end
  end

  defp validate_payload(raw) do
    required_keys = ~w(line_items currency due_date)a

    missing = Enum.reject(required_keys, &Map.has_key?(raw, &1))

    cond do
      missing != [] ->
        {:error, :validation, {:missing_keys, missing}}

      not valid_currency?(raw.currency) ->
        {:error, :validation, {:unsupported_currency, raw.currency}}

      Decimal.gt?(total_amount(raw.line_items), @max_invoice_amount) ->
        {:error, :validation, :amount_exceeds_limit}

      true ->
        {:ok, raw}
    end
  end

  defp persist_invoice(customer, payload, tax_lines) do
    attrs = %{
      customer_id:  customer.id,
      currency:     payload.currency,
      due_date:     payload.due_date,
      line_items:   payload.line_items,
      tax_lines:    tax_lines,
      total:        compute_total(payload.line_items, tax_lines),
      status:       :pending,
      issued_at:    DateTime.utc_now()
    }

    %Invoice{}
    |> Invoice.changeset(attrs)
    |> Repo.insert()
  end

  defp notify_customer(customer, invoice) do
    Mailer.send_invoice_confirmation(customer.email, %{
      invoice_id: invoice.id,
      total:      invoice.total,
      due_date:   invoice.due_date
    })
  end

  defp valid_currency?(code) when is_binary(code) do
    code in ~w(USD EUR GBP BRL JPY CAD AUD)
  end

  defp valid_currency?(_), do: false

  defp total_amount(line_items) do
    Enum.reduce(line_items, Decimal.new("0"), fn item, acc ->
      Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
    end)
  end

  defp compute_total(line_items, tax_lines) do
    subtotal = total_amount(line_items)

    tax_total =
      Enum.reduce(tax_lines, Decimal.new("0"), fn tl, acc ->
        Decimal.add(acc, tl.amount)
      end)

    Decimal.add(subtotal, tax_total)
  end
end
```

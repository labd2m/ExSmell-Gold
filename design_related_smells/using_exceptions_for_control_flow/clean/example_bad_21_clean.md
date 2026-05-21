```elixir
defmodule PaymentGateway do
  @moduledoc """
  Low-level wrapper around the external payment processor API.
  Handles charge creation, idempotency keys, and response parsing.
  """

  alias PaymentGateway.{CardError, AmountError, CustomerError}

  defmodule CardError do
    defexception [:message, :decline_code]
  end

  defmodule AmountError do
    defexception [:message]
  end

  defmodule CustomerError do
    defexception [:message]
  end

  @min_amount_cents 50
  @max_amount_cents 99_999_99

  def charge(customer_id, amount_cents) when is_binary(customer_id) do
    unless is_integer(amount_cents) and amount_cents >= @min_amount_cents do
      raise AmountError,
        message: "Amount must be an integer >= #{@min_amount_cents} cents, got: #{inspect(amount_cents)}"
    end

    if amount_cents > @max_amount_cents do
      raise AmountError,
        message: "Amount #{amount_cents} exceeds maximum charge limit of #{@max_amount_cents} cents"
    end

    customer = fetch_customer!(customer_id)

    result = simulate_processor_call(customer, amount_cents)

    case result do
      {:ok, charge_id} ->
        %{
          charge_id: charge_id,
          customer_id: customer_id,
          amount_cents: amount_cents,
          status: :succeeded,
          charged_at: DateTime.utc_now()
        }

      {:declined, decline_code} ->
        raise CardError,
          message: "Card was declined for customer #{customer_id}",
          decline_code: decline_code

      {:error, :invalid_card} ->
        raise CardError,
          message: "Invalid or expired card on file for customer #{customer_id}",
          decline_code: :invalid_card
    end
  end

  def charge(customer_id, _amount_cents) do
    raise CustomerError,
      message: "customer_id must be a non-empty string, got: #{inspect(customer_id)}"
  end

  defp fetch_customer!(customer_id) do
    case lookup_customer(customer_id) do
      nil ->
        raise CustomerError, message: "No customer found with id #{customer_id}"

      customer ->
        customer
    end
  end

  defp lookup_customer("cus_" <> _rest = id) do
    %{id: id, card_last4: "4242", card_brand: :visa, active: true}
  end

  defp lookup_customer(_), do: nil

  defp simulate_processor_call(%{card_last4: "0002"}, _amount), do: {:declined, :insufficient_funds}
  defp simulate_processor_call(%{card_last4: "0119"}, _amount), do: {:error, :invalid_card}
  defp simulate_processor_call(_customer, _amount), do: {:ok, "ch_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"}
end

defmodule BillingService do
  @moduledoc """
  Orchestrates payment collection for outstanding invoices.
  """

  require Logger

  def process_payment(invoice) do
    Logger.info("Processing payment for invoice #{invoice.id}, customer #{invoice.customer_id}")

    # try...rescue to handle predictable outcomes like card declines or invalid
    # amounts, which are not exceptional but ordinary business cases.
    try do
      charge = PaymentGateway.charge(invoice.customer_id, invoice.amount_cents)

      Logger.info("Charge #{charge.charge_id} succeeded for invoice #{invoice.id}")
      {:ok, Map.put(invoice, :charge, charge)}
    rescue
      e in PaymentGateway.CardError ->
        Logger.warning("Card declined for invoice #{invoice.id}: #{e.message}")
        {:error, {:card_declined, e.decline_code}}

      e in PaymentGateway.AmountError ->
        Logger.error("Invalid amount on invoice #{invoice.id}: #{e.message}")
        {:error, {:invalid_amount, e.message}}

      e in PaymentGateway.CustomerError ->
        Logger.error("Customer error on invoice #{invoice.id}: #{e.message}")
        {:error, {:customer_not_found, e.message}}
    end
  end

  def retry_failed_invoices(invoices) do
    Enum.reduce(invoices, {[], []}, fn invoice, {ok_acc, err_acc} ->
      case process_payment(invoice) do
        {:ok, updated} -> {[updated | ok_acc], err_acc}
        {:error, reason} -> {ok_acc, [{invoice.id, reason} | err_acc]}
      end
    end)
  end
end
```

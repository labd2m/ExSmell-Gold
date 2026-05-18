```elixir
defmodule Payments.ChargeProcessor do
  @moduledoc """
  Orchestrates the charge lifecycle for customer orders.
  Communicates with the payment gateway and records the outcome.
  """

  require Logger

  alias Payments.{GatewayClient, ChargeRepo, CustomerRepo, ReceiptMailer}

  @max_amount_cents 1_000_000_00
  @supported_currencies ~w(USD EUR GBP BRL CAD AUD)

  @spec charge(String.t(), non_neg_integer(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def charge(customer_id, amount_cents, currency, metadata \\ %{}) do
    Logger.info("Processing charge",
      customer_id: customer_id,
      amount: amount_cents,
      currency: currency
    )

    with :ok <- validate_amount(amount_cents),
         :ok <- validate_currency(currency),
         {:ok, customer} <- CustomerRepo.get(customer_id),
         {:ok, payment_method_id} <- resolve_payment_method(customer),
         {:ok, raw_charge} <-
           GatewayClient.create_charge(%{
             amount: amount_cents,
             currency: currency,
             payment_method: payment_method_id,
             metadata: metadata
           }),
         {:ok, charge} <- parse_charge_response(raw_charge),
         {:ok, record} <- ChargeRepo.insert(charge),
         :ok <- maybe_send_receipt(customer, record) do
      {:ok, record}
    else
      {:error, reason} = err ->
        Logger.error("Charge failed",
          customer_id: customer_id,
          amount: amount_cents,
          reason: inspect(reason)
        )
        err
    end
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0 and amount <= @max_amount_cents,
    do: :ok

  defp validate_amount(_), do: {:error, :invalid_amount}

  defp validate_currency(currency) when currency in @supported_currencies, do: :ok
  defp validate_currency(currency), do: {:error, {:unsupported_currency, currency}}

  defp resolve_payment_method(%{default_payment_method_id: nil}),
    do: {:error, :no_payment_method_on_file}

  defp resolve_payment_method(%{default_payment_method_id: id}), do: {:ok, id}

  defp parse_charge_response(%{"id" => id, "status" => status} = raw) do
    with {:ok, method_type} <- decode_payment_method(raw["payment_method_details"]["type"]) do
      {:ok,
       %{
         gateway_charge_id: id,
         status: status,
         amount_cents: raw["amount"],
         currency: raw["currency"],
         payment_method_type: method_type,
         last_four: get_in(raw, ["payment_method_details", "card", "last4"]),
         charged_at: DateTime.from_unix!(raw["created"])
       }}
    end
  end

  defp parse_charge_response(_), do: {:error, :malformed_charge_response}

  defp decode_payment_method(nil), do: {:ok, :unknown}

  defp decode_payment_method(type) when is_binary(type) do
    {:ok, String.to_atom(type)}
  end

  defp decode_payment_method(_), do: {:error, :invalid_payment_method_type}

  defp maybe_send_receipt(%{email: email}, charge) when is_binary(email) do
    case ReceiptMailer.send(email, charge) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Receipt email failed", reason: inspect(reason))
        :ok
    end
  end

  defp maybe_send_receipt(_, _), do: :ok
end
```

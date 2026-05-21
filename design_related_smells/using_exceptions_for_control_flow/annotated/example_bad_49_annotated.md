# Annotated Example — Code Smell

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `CurrencyConverter.convert/3`
- **Affected function(s):** `CurrencyConverter.convert/3`, `PaymentGateway.charge/2`
- **Short explanation:** `CurrencyConverter.convert/3` raises `UnsupportedCurrencyError` and `NegativeAmountError` for conditions that are entirely predictable in a payment system — currency codes passed from user input may easily be unsupported, and validation of amounts is routine. With no `{:ok, converted} | {:error, reason}` path available, `PaymentGateway.charge/2` is forced to rely on `try/rescue` for ordinary pre-charge validation flow.

---

## Code

```elixir
defmodule CurrencyConverter do
  @moduledoc """
  Converts monetary amounts between supported currencies using
  fixed exchange rates for the payments subsystem.
  """

  defmodule UnsupportedCurrencyError do
    defexception [:message, :currency]

    @impl true
    def exception(opts) do
      currency = Keyword.fetch!(opts, :currency)
      %__MODULE__{
        message: "Currency #{currency} is not supported",
        currency: currency
      }
    end
  end

  defmodule NegativeAmountError do
    defexception [:message, :amount]

    @impl true
    def exception(opts) do
      amount = Keyword.fetch!(opts, :amount)
      %__MODULE__{
        message: "Amount must be positive, got: #{amount}",
        amount: amount
      }
    end
  end

  # Rates relative to USD
  @exchange_rates %{
    "USD" => Decimal.new("1.0"),
    "BRL" => Decimal.new("5.03"),
    "EUR" => Decimal.new("0.92"),
    "GBP" => Decimal.new("0.79"),
    "CAD" => Decimal.new("1.36"),
    "JPY" => Decimal.new("149.82")
  }

  @supported_currencies Map.keys(@exchange_rates)

  def supported_currencies, do: @supported_currencies

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because convert/3 raises UnsupportedCurrencyError
  # VALIDATION: and NegativeAmountError for expected, predictable input problems.
  # VALIDATION: In a payment gateway that accepts user-supplied currency codes,
  # VALIDATION: unsupported values and invalid amounts are ordinary validation
  # VALIDATION: failures — not exceptional events. Because no non-raising variant
  # VALIDATION: exists, callers like PaymentGateway.charge/2 must use try/rescue
  # VALIDATION: as their only tool for distinguishing valid from invalid conversions.
  def convert(amount, from_currency, to_currency) do
    unless is_number(amount) or Decimal.is_decimal(amount) do
      raise ArgumentError, "amount must be a number or Decimal, got: #{inspect(amount)}"
    end

    decimal_amount = if Decimal.is_decimal(amount), do: amount, else: Decimal.new("#{amount}")

    if Decimal.negative?(decimal_amount) or Decimal.equal?(decimal_amount, Decimal.new("0")) do
      raise NegativeAmountError, amount: amount
    end

    from = String.upcase(from_currency)
    to = String.upcase(to_currency)

    unless from in @supported_currencies do
      raise UnsupportedCurrencyError, currency: from
    end

    unless to in @supported_currencies do
      raise UnsupportedCurrencyError, currency: to
    end

    from_rate = Map.fetch!(@exchange_rates, from)
    to_rate = Map.fetch!(@exchange_rates, to)

    usd_amount = Decimal.div(decimal_amount, from_rate)
    converted = Decimal.mult(usd_amount, to_rate)
    rounded = Decimal.round(converted, 2)

    %{
      original_amount: decimal_amount,
      from_currency: from,
      converted_amount: rounded,
      to_currency: to,
      rate: Decimal.div(to_rate, from_rate) |> Decimal.round(6),
      converted_at: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END

  def format_amount(%Decimal{} = amount, currency) do
    "#{currency} #{Decimal.to_string(amount)}"
  end
end

defmodule PaymentGateway do
  @moduledoc """
  Processes customer charges, normalising amounts to USD before submission
  to the downstream payment processor.
  """

  require Logger

  alias CurrencyConverter
  alias CurrencyConverter.{UnsupportedCurrencyError, NegativeAmountError}

  @processing_currency "USD"

  def charge(customer, charge_request) do
    amount = charge_request.amount
    currency = charge_request.currency
    description = Map.get(charge_request, :description, "Purchase")

    Logger.info(
      "Processing charge of #{amount} #{currency} for customer #{customer.id}"
    )

    # Forced to use try/rescue because CurrencyConverter.convert/3 raises
    # exceptions for predictable input validation failures.
    try do
      conversion = CurrencyConverter.convert(amount, currency, @processing_currency)

      charge_result = %{
        charge_id: generate_charge_id(),
        customer_id: customer.id,
        original_amount: conversion.original_amount,
        original_currency: conversion.from_currency,
        processed_amount: conversion.converted_amount,
        processing_currency: @processing_currency,
        exchange_rate: conversion.rate,
        description: description,
        status: :succeeded,
        charged_at: DateTime.utc_now()
      }

      Logger.info(
        "Charge #{charge_result.charge_id} succeeded: " <>
          "#{CurrencyConverter.format_amount(conversion.converted_amount, @processing_currency)}"
      )

      {:ok, charge_result}
    rescue
      e in UnsupportedCurrencyError ->
        Logger.info("Rejected charge for customer #{customer.id}: #{e.message}")
        {:error, {:unsupported_currency, e.message}}

      e in NegativeAmountError ->
        Logger.warning("Rejected invalid charge amount from customer #{customer.id}: #{e.message}")
        {:error, {:invalid_amount, e.message}}
    end
  end

  def refund(charge_id, amount_cents) do
    Logger.info("Issuing refund of #{amount_cents} cents for charge #{charge_id}")
    {:ok, %{refund_id: generate_charge_id(), charge_id: charge_id, status: :refunded}}
  end

  defp generate_charge_id do
    "ch_" <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end
end
```

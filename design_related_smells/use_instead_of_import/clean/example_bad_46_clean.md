```elixir
defmodule MoneyMath do
  @minor_unit_factors %{
    "USD" => 100, "EUR" => 100, "GBP" => 100,
    "JPY" => 1,   "KWD" => 1000, "BHD" => 1000,
    "BRL" => 100, "CAD" => 100, "AUD" => 100
  }

  def to_minor_units(amount, currency) do
    factor = Map.get(@minor_unit_factors, currency, 100)
    round(amount * factor)
  end

  def from_minor_units(minor, currency) do
    factor = Map.get(@minor_unit_factors, currency, 100)
    minor / factor
  end

  def add(a, b), do: Float.round(a + b, 10)
  def subtract(a, b), do: Float.round(a - b, 10)
  def multiply(amount, factor), do: Float.round(amount * factor, 10)
end

defmodule CurrencyHelpers do
  defmacro __using__(_opts) do
    quote do
      import MoneyMath

      def format_amount(amount, currency) do
        formatted = :erlang.float_to_binary(amount / 1, decimals: 2)
        "#{currency} #{formatted}"
      end

      def zero?(amount), do: amount == 0 or amount == 0.0

      def positive?(amount), do: amount > 0

      def negate(amount), do: amount * -1
    end
  end
end

defmodule PaymentGateway do
  use CurrencyHelpers

  @supported_currencies ~w(USD EUR GBP JPY BRL CAD AUD)
  @max_charge_usd       999_999.99
  @refund_window_days   180

  def charge(order, payment_method) do
    with :ok <- validate_currency(order.currency),
         :ok <- validate_amount(order.amount),
         true <- positive?(order.amount) do
      minor = to_minor_units(order.amount, order.currency)

      result = simulate_charge(minor, payment_method)

      case result do
        {:ok, charge_id} ->
          {:ok, build_receipt(order, charge_id)}
        {:error, reason} ->
          {:error, reason}
      end
    else
      false          -> {:error, :non_positive_amount}
      {:error, _} = e -> e
    end
  end

  def refund(original_receipt, amount \\ nil) do
    refund_amount = amount || original_receipt.amount
    days_since    = DateTime.diff(DateTime.utc_now(), original_receipt.charged_at, :day)

    cond do
      days_since > @refund_window_days ->
        {:error, :refund_window_expired}
      refund_amount > original_receipt.amount ->
        {:error, :refund_exceeds_original}
      not positive?(refund_amount) ->
        {:error, :invalid_refund_amount}
      true ->
        minor    = to_minor_units(refund_amount, original_receipt.currency)
        net      = subtract(original_receipt.amount, refund_amount)
        {:ok, %{
          refund_id:     "rfnd_#{:erlang.unique_integer([:positive])}",
          original_id:   original_receipt.charge_id,
          refund_amount: refund_amount,
          refund_fmt:    format_amount(refund_amount, original_receipt.currency),
          net_charged:   net,
          minor_units:   minor,
          refunded_at:   DateTime.utc_now()
        }}
    end
  end

  def build_receipt(order, charge_id) do
    fee   = multiply(order.amount, 0.029) |> add(0.30)
    net   = subtract(order.amount, fee)

    %{
      charge_id:    charge_id,
      order_id:     order.id,
      amount:       order.amount,
      amount_fmt:   format_amount(order.amount, order.currency),
      fee:          fee,
      fee_fmt:      format_amount(fee, order.currency),
      net:          net,
      net_fmt:      format_amount(net, order.currency),
      currency:     order.currency,
      minor_units:  to_minor_units(order.amount, order.currency),
      charged_at:   DateTime.utc_now(),
      status:       :succeeded
    }
  end

  defp validate_currency(currency) do
    if currency in @supported_currencies, do: :ok, else: {:error, :unsupported_currency}
  end

  defp validate_amount(amount) do
    if amount <= @max_charge_usd, do: :ok, else: {:error, :amount_exceeds_limit}
  end

  defp simulate_charge(_minor, _method) do
    {:ok, "ch_#{:erlang.unique_integer([:positive])}"}
  end
end
```

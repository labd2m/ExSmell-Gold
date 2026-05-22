```elixir
defmodule Payments.CardHelpers do
  @moduledoc """
  Pure utility functions for card number handling, validation,
  and charge descriptor construction. No network calls.
  """

  def mask_pan(pan) when is_binary(pan) do
    len = String.length(pan)
    last4 = String.slice(pan, -4, 4)
    String.duplicate("*", max(len - 4, 0)) <> last4
  end

  def detect_brand("4" <> _),            do: :visa
  def detect_brand("51" <> _),           do: :mastercard
  def detect_brand("52" <> _),           do: :mastercard
  def detect_brand("53" <> _),           do: :mastercard
  def detect_brand("54" <> _),           do: :mastercard
  def detect_brand("55" <> _),           do: :mastercard
  def detect_brand("34" <> _),           do: :amex
  def detect_brand("37" <> _),           do: :amex
  def detect_brand(_),                   do: :unknown

  def luhn_valid?(pan) when is_binary(pan) do
    digits = pan |> String.graphemes() |> Enum.map(&String.to_integer/1)
    check  = Enum.reduce(Enum.with_index(digits), 0, fn {d, i}, acc ->
      if rem(length(digits) - i, 2) == 0 do
        doubled = d * 2
        acc + if doubled > 9, do: doubled - 9, else: doubled
      else
        acc + d
      end
    end)
    rem(check, 10) == 0
  end

  def build_descriptor(merchant_name, reference) do
    name = merchant_name |> String.upcase() |> String.slice(0, 18)
    "#{name}*#{reference}"
  end

  def cents_to_decimal(cents), do: cents / 100

  defmacro __using__(_opts) do
    quote do
      import Payments.CardHelpers
      alias Payments.FraudDetector

      @max_charge_attempts 3
      @charge_timeout_ms   5_000
    end
  end
end

defmodule Payments.FraudDetector do
  @moduledoc "Stub for real-time fraud scoring (returns safe for all in this stub)."

  def score(%{amount_cents: a}) when a > 100_000, do: {:ok, %{score: 78, risk: :high}}
  def score(_card_context),                        do: {:ok, %{score: 12, risk: :low}}

  def block?(%{risk: :high}), do: true
  def block?(_),              do: false
end

defmodule Payments.ChargeService do
  use Payments.CardHelpers
  
  @moduledoc """
  Processes card charges, refunds, and void operations against the payment gateway.
  Includes fraud pre-screening and automatic retry on transient failures.
  """

  def charge(%{pan: pan, amount_cents: amount} = card_params, merchant) do
    with true <- luhn_valid?(pan),
         brand = detect_brand(pan),
         {:ok, fraud} <- FraudDetector.score(%{amount_cents: amount, brand: brand}),
         false <- FraudDetector.block?(fraud) do
      descriptor = build_descriptor(merchant[:name], generate_ref())
      attempt_charge(card_params, descriptor, amount, @max_charge_attempts)
    else
      false           -> {:error, :invalid_card_number}
      {:error, _} = e -> e
      true            -> {:error, :fraud_block}
    end
  end

  def refund(%{charge_id: charge_id, amount_cents: amount}, reason \\ :requested_by_customer) do
    IO.puts("[Gateway] Refunding #{cents_to_decimal(amount)} for charge #{charge_id} — #{reason}")
    {:ok, %{refund_id: "RFD-" <> generate_ref(), charge_id: charge_id, amount_cents: amount, reason: reason}}
  end

  def void_authorization(%{auth_id: auth_id}) do
    IO.puts("[Gateway] Voiding authorization #{auth_id}")
    {:ok, %{voided_auth: auth_id, voided_at: DateTime.utc_now()}}
  end

  def describe_charge(%{pan: pan, amount_cents: amount, status: status}) do
    """
    Card    : #{mask_pan(pan)} (#{detect_brand(pan)})
    Amount  : #{cents_to_decimal(amount)}
    Status  : #{status}
    """
  end

  defp attempt_charge(_params, _descriptor, _amount, 0) do
    {:error, :max_retries_exceeded}
  end

  defp attempt_charge(params, descriptor, amount, attempts) do
    case simulate_gateway(params, descriptor, amount) do
      {:ok, _} = ok -> ok
      {:error, :timeout} ->
        Process.sleep(div(@charge_timeout_ms, @max_charge_attempts))
        attempt_charge(params, descriptor, amount, attempts - 1)
      {:error, _} = err -> err
    end
  end

  defp simulate_gateway(%{pan: pan}, descriptor, amount) do
    {:ok, %{
      charge_id:  "CHG-" <> generate_ref(),
      pan:        pan,
      descriptor: descriptor,
      amount:     amount,
      status:     :captured,
      charged_at: DateTime.utc_now()
    }}
  end

  defp generate_ref, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
```

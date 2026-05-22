```elixir
defmodule Payments.RoundingUtils do
  @moduledoc """
  Financial rounding helpers adhering to banker's rounding (half-even)
  and standard ceiling/floor conventions used across payment processing.
  """

  def round_half_even(value, precision \\ 2) do
    factor = :math.pow(10, precision) |> round()
    scaled = value * factor

    rounded =
      if scaled - trunc(scaled) == 0.5 do
        even = trunc(scaled)
        if rem(even, 2) == 0, do: even, else: even + 1
      else
        round(scaled)
      end

    rounded / factor
  end

  def ceil_to_cent(value), do: Float.ceil(value, 2)
  def floor_to_cent(value), do: Float.floor(value, 2)

  def truncate_to_cent(value) do
    (trunc(value * 100)) / 100
  end
end

defmodule Payments.CurrencyHelpers do
  @moduledoc """
  Currency conversion, formatting, and minor-unit helpers, shared across
  payment modules via `use`.
  """

  @exchange_rates %{
    usd: 1.0,
    eur: 1.09,
    gbp: 1.28,
    brl: 0.18
  }

  defmacro __using__(_opts) do
    quote do
      import Payments.RoundingUtils  # propagates rounding dependency into caller

      def format_amount(cents, currency \\ :usd) when is_integer(cents) do
        symbol = case currency do
          :usd -> "$"
          :eur -> "€"
          :gbp -> "£"
          :brl -> "R$"
          _    -> to_string(currency) <> " "
        end

        dollars = div(cents, 100)
        rem_    = abs(rem(cents, 100))
        "#{symbol}#{dollars}.#{String.pad_leading(to_string(rem_), 2, "0")}"
      end

      def cents_to_major(cents) when is_integer(cents), do: cents / 100

      def major_to_cents(amount) when is_float(amount) do
        amount |> round_half_even(2) |> then(&round(&1 * 100))
      end

      def convert(cents, from_currency, to_currency) do
        rates = unquote(Macro.escape(@exchange_rates))
        from_rate = Map.fetch!(rates, from_currency)
        to_rate   = Map.fetch!(rates, to_currency)
        round(cents * to_rate / from_rate)
      end
    end
  end
end

defmodule Payments.TransactionHandler do
  @moduledoc """
  Processes payment transactions including authorization, capture, partial
  refunds, and currency conversion for multi-currency accounts.
  """

  use Payments.CurrencyHelpers

  @max_transaction_cents 1_000_000_00  # $1,000,000.00
  @refund_window_seconds 90 * 86_400   # 90 days

  def authorize(account, amount_cents, currency \\ :usd) do
    with :ok <- check_amount(amount_cents),
         :ok <- check_balance(account, amount_cents, currency) do
      txn = %{
        id:           transaction_id(),
        account_id:   account.id,
        type:         :authorization,
        amount_cents: amount_cents,
        currency:     currency,
        status:       :authorized,
        created_at:   DateTime.utc_now(),
        captured_at:  nil,
        refunded_at:  nil
      }

      {:ok, txn}
    end
  end

  def capture(%{status: :authorized, amount_cents: auth_cents} = txn, capture_cents \\ nil) do
    final_cents = capture_cents || auth_cents

    if final_cents > auth_cents do
      {:error, :capture_exceeds_authorization}
    else
      {:ok, %{txn | status: :captured, amount_cents: final_cents, captured_at: DateTime.utc_now()}}
    end
  end

  def capture(_txn, _), do: {:error, :not_authorized}

  def refund(%{status: :captured} = txn, refund_cents \\ nil) do
    with :ok <- within_refund_window?(txn) do
      amount = refund_cents || txn.amount_cents

      if amount > txn.amount_cents do
        {:error, :refund_exceeds_captured}
      else
        refund_txn = %{
          id:           transaction_id(),
          account_id:   txn.account_id,
          type:         :refund,
          amount_cents: amount,
          currency:     txn.currency,
          status:       :completed,
          parent_id:    txn.id,
          created_at:   DateTime.utc_now()
        }
        {:ok, refund_txn}
      end
    end
  end

  def refund(_, _), do: {:error, :not_captured}

  def receipt_line(txn) do
    type_str = txn.type |> to_string() |> String.upcase()
    "#{type_str}  #{format_amount(txn.amount_cents, txn.currency)}  [#{txn.id}]"
  end

  defp check_amount(cents) when cents <= 0,                   do: {:error, :non_positive_amount}
  defp check_amount(cents) when cents > @max_transaction_cents, do: {:error, :amount_too_large}
  defp check_amount(_),                                         do: :ok

  defp check_balance(account, cents, currency) do
    account_cents = convert(cents, currency, account.base_currency)
    if account.balance_cents >= account_cents, do: :ok, else: {:error, :insufficient_funds}
  end

  defp within_refund_window?(%{captured_at: captured_at}) do
    elapsed = DateTime.diff(DateTime.utc_now(), captured_at, :second)
    if elapsed <= @refund_window_seconds, do: :ok, else: {:error, :refund_window_expired}
  end

  defp transaction_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false) |> then(&"txn_#{&1}")
  end
end
```

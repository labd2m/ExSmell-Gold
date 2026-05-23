```elixir
defmodule Payments.CardProcessor do
  @moduledoc """
  Handles credit/debit card operations including authorization and charging.
  All card data is validated locally before being forwarded to the payment gateway.
  """

  alias Payments.Gateway
  alias Payments.Transaction
  alias Payments.Repo

  @doc """
  Authorizes a hold on the card for the given amount (in cents).
  Does not capture funds immediately.
  """
  def authorize(card, amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    with :ok <- validate_luhn(card.number),
         :ok <- validate_expiry(card.exp_month, card.exp_year),
         :ok <- validate_cvv(card.cvv) do
      Gateway.authorize(%{
        card_number: card.number,
        exp_month: card.exp_month,
        exp_year: card.exp_year,
        cvv: card.cvv,
        amount: amount_cents,
        currency: "USD"
      })
    end
    |> case do
      {:ok, auth_code} ->
        txn = %Transaction{
          type: :authorization,
          amount_cents: amount_cents,
          auth_code: auth_code,
          card_last4: String.slice(card.number, -4, 4),
          status: :authorized
        }

        Repo.insert(txn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Charges the card immediately for the given amount (in cents).
  Captures funds in a single step.
  """
  def charge(card, amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    with :ok <- validate_luhn(card.number),
         :ok <- validate_expiry(card.exp_month, card.exp_year),
         :ok <- validate_cvv(card.cvv) do
      Gateway.charge(%{
        card_number: card.number,
        exp_month: card.exp_month,
        exp_year: card.exp_year,
        cvv: card.cvv,
        amount: amount_cents,
        currency: "USD"
      })
    end
    |> case do
      {:ok, charge_id} ->
        txn = %Transaction{
          type: :charge,
          amount_cents: amount_cents,
          gateway_id: charge_id,
          card_last4: String.slice(card.number, -4, 4),
          status: :captured
        }

        Repo.insert(txn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refunds a previously captured transaction.
  """
  def refund(transaction_id, amount_cents) do
    case Repo.get(Transaction, transaction_id) do
      nil -> {:error, :not_found}
      txn when txn.status != :captured -> {:error, :not_refundable}
      txn -> Gateway.refund(txn.gateway_id, amount_cents)
    end
  end

  defp validate_luhn(number) do
    digits = String.graphemes(number) |> Enum.map(&String.to_integer/1) |> Enum.reverse()
    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc ->
        if rem(i, 2) == 1 do
          doubled = d * 2
          acc + if(doubled > 9, do: doubled - 9, else: doubled)
        else
          acc + d
        end
      end)
    if rem(sum, 10) == 0, do: :ok, else: {:error, :invalid_card_number}
  end

  defp validate_expiry(month, year) do
    now = Date.utc_today()
    exp = Date.new!(year, month, 1) |> Date.end_of_month()
    if Date.compare(exp, now) == :lt, do: {:error, :card_expired}, else: :ok
  end

  defp validate_cvv(cvv) do
    if String.length(cvv) in [3, 4], do: :ok, else: {:error, :invalid_cvv}
  end
end
```

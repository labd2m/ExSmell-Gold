```elixir
defmodule Billing.Card do
  @moduledoc "Represents a payment card and provides validation helpers."

  @enforce_keys [:number, :expiry_month, :expiry_year, :cvv, :holder]
  defstruct [:number, :expiry_month, :expiry_year, :cvv, :holder]

  def valid?(%__MODULE__{expiry_year: year, expiry_month: month}) do
    today = Date.utc_today()
    year > today.year or (year == today.year and month >= today.month)
  end
end

defmodule Billing.Receipt do
  @moduledoc "Builds a receipt struct from a gateway transaction."

  defstruct [:transaction_id, :amount, :currency, :issued_at]

  def build(transaction_id, amount, currency) do
    %__MODULE__{
      transaction_id: transaction_id,
      amount: amount,
      currency: currency,
      issued_at: DateTime.utc_now()
    }
  end
end

defmodule Billing.GatewayAdapter do
  @moduledoc "Thin adapter over the external payment gateway HTTP client."

  def submit(_card, amount, _currency) when amount > 10_000, do: {:error, "amount_exceeds_limit"}
  def submit(_card, _amount, _currency), do: {:ok, "txn_#{:rand.uniform(999_999)}"}

  def refund(transaction_id, _amount) when is_binary(transaction_id),
    do: {:ok, "ref_#{:rand.uniform(999_999)}"}
end

defmodule Billing.PaymentProcessor do
  @moduledoc """
  Handles payment processing for subscription and one-time charges.
  Integrates with the configured payment gateway adapter.
  """

  alias Billing.{Card, GatewayAdapter, Receipt}

  @supported_currencies ~w[USD EUR GBP BRL CAD AUD]

  def charge(%Card{} = card, amount, currency) do
    unless currency in @supported_currencies do
      raise RuntimeError,
        message: "Unsupported currency '#{currency}'. Accepted: #{Enum.join(@supported_currencies, ", ")}"
    end

    unless is_number(amount) and amount > 0 do
      raise RuntimeError,
        message: "Invalid charge amount: #{inspect(amount)}. Must be a positive number."
    end

    unless Card.valid?(card) do
      raise RuntimeError, message: "Card is invalid or has expired"
    end

    case GatewayAdapter.submit(card, amount, currency) do
      {:ok, transaction_id} ->
        Receipt.build(transaction_id, amount, currency)

      {:error, reason} ->
        raise RuntimeError, message: "Gateway rejected the charge: #{reason}"
    end
  end

  def refund(transaction_id, amount)
      when is_binary(transaction_id) and is_number(amount) and amount > 0 do
    case GatewayAdapter.refund(transaction_id, amount) do
      {:ok, refund_id} -> {:ok, refund_id}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Billing.SubscriptionCharger do
  @moduledoc """
  Charges active subscribers on their renewal date.
  Delegates to PaymentProcessor for the actual gateway interaction.
  """

  require Logger

  alias Billing.{Card, PaymentProcessor}

  defmodule Subscription do
    defstruct [:id, :user_id, :amount, :currency, :plan, :status]
  end

  defmodule User do
    defstruct [:id, :email, :primary_card]
  end

  def charge_subscriber(%User{} = user, %Subscription{} = subscription) do
    card = %Card{
      number: "4111111111111111",
      expiry_month: 12,
      expiry_year: 2027,
      cvv: "123",
      holder: user.email
    }

    # Client forced to use try/rescue because PaymentProcessor.charge/3 raises
    # instead of returning {:ok, receipt} | {:error, reason}.
    try do
      receipt =
        PaymentProcessor.charge(card, subscription.amount, subscription.currency)

      Logger.info(
        "Successfully charged user=#{user.id} amount=#{subscription.amount} " <>
          "currency=#{subscription.currency} txn=#{receipt.transaction_id}"
      )

      {:ok, receipt}
    rescue
      e in RuntimeError ->
        Logger.warning(
          "Charge failed for user=#{user.id} subscription=#{subscription.id}: #{e.message}"
        )

        {:error, e.message}
    end
  end

  def charge_all_due(subscriptions, users_by_id) do
    Enum.reduce(subscriptions, %{ok: [], failed: []}, fn sub, acc ->
      user = Map.fetch!(users_by_id, sub.user_id)

      case charge_subscriber(user, sub) do
        {:ok, receipt} ->
          Map.update!(acc, :ok, &[%{subscription_id: sub.id, receipt: receipt} | &1])

        {:error, reason} ->
          Map.update!(acc, :failed, &[%{subscription_id: sub.id, reason: reason} | &1])
      end
    end)
  end
end
```

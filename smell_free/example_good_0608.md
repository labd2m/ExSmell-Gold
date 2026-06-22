```elixir
defmodule Billing.Gateway do
  @moduledoc """
  Defines the behaviour that all payment gateway adapters must implement.
  Adapters for Stripe, Braintree, or Adyen are selected at runtime from
  application configuration, enabling clean gateway switching and A/B testing
  without changing call sites. All gateway interactions return typed result
  tuples so the billing context handles errors uniformly regardless of the
  underlying provider.
  """

  @type charge_attrs :: %{
          required(:amount_cents) => pos_integer(),
          required(:currency) => binary(),
          required(:customer_id) => binary(),
          optional(:description) => binary(),
          optional(:metadata) => map()
        }

  @type charge_result :: %{
          gateway_ref: binary(),
          status: :succeeded | :pending | :failed,
          amount_cents: pos_integer(),
          currency: binary(),
          gateway_fee_cents: non_neg_integer() | nil
        }

  @type refund_attrs :: %{
          required(:gateway_ref) => binary(),
          required(:amount_cents) => pos_integer(),
          required(:reason) => binary()
        }

  @type refund_result :: %{
          refund_ref: binary(),
          status: :succeeded | :pending,
          amount_cents: pos_integer()
        }

  @callback authorize(charge_attrs()) :: {:ok, charge_result()} | {:error, term()}
  @callback capture(binary()) :: {:ok, charge_result()} | {:error, term()}
  @callback charge(charge_attrs()) :: {:ok, charge_result()} | {:error, term()}
  @callback refund(refund_attrs()) :: {:ok, refund_result()} | {:error, term()}
  @callback void(binary()) :: :ok | {:error, term()}

  @doc """
  Returns the configured gateway adapter module. Falls back to the Stripe
  adapter when no explicit configuration is present.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:my_app, :payment_gateway, Billing.Gateways.Stripe)
  end

  @doc """
  Delegates `authorize/1` to the configured adapter.
  """
  @spec authorize(charge_attrs()) :: {:ok, charge_result()} | {:error, term()}
  def authorize(attrs), do: adapter().authorize(attrs)

  @doc """
  Delegates `charge/1` to the configured adapter.
  """
  @spec charge(charge_attrs()) :: {:ok, charge_result()} | {:error, term()}
  def charge(attrs), do: adapter().charge(attrs)

  @doc """
  Delegates `refund/1` to the configured adapter.
  """
  @spec refund(refund_attrs()) :: {:ok, refund_result()} | {:error, term()}
  def refund(attrs), do: adapter().refund(attrs)
end

defmodule Billing.Gateways.Stripe do
  @moduledoc """
  Stripe payment gateway adapter implementing the `Billing.Gateway` behaviour.
  Translates between the application's domain types and Stripe's API contract.
  """

  @behaviour Billing.Gateway

  alias Integrations.StripeClient

  require Logger

  @impl Billing.Gateway
  def authorize(%{amount_cents: amount, currency: currency, customer_id: customer_id} = attrs) do
    params = %{
      amount: amount,
      currency: String.downcase(currency),
      customer: customer_id,
      capture_method: "manual",
      description: Map.get(attrs, :description),
      metadata: Map.get(attrs, :metadata, %{})
    }

    case StripeClient.create_payment_intent(params) do
      {:ok, intent} -> {:ok, build_charge_result(intent)}
      {:error, {_type, _status, stripe_error}} -> {:error, translate_error(stripe_error)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Billing.Gateway
  def capture(gateway_ref) when is_binary(gateway_ref) do
    case StripeClient.confirm_payment_intent(gateway_ref, %{}) do
      {:ok, intent} -> {:ok, build_charge_result(intent)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Billing.Gateway
  def charge(attrs) do
    with {:ok, auth_result} <- authorize(Map.put(attrs, :capture_method, "automatic")) do
      {:ok, auth_result}
    end
  end

  @impl Billing.Gateway
  def refund(%{gateway_ref: ref, amount_cents: amount, reason: reason}) do
    case StripeClient.create_refund(%{payment_intent: ref, amount: amount, reason: reason}) do
      {:ok, refund} ->
        {:ok, %{refund_ref: refund["id"], status: :succeeded, amount_cents: refund["amount"]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Billing.Gateway
  def void(gateway_ref) when is_binary(gateway_ref) do
    case StripeClient.cancel_payment_intent(gateway_ref) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_charge_result(intent) do
    %{
      gateway_ref: intent["id"],
      status: translate_status(intent["status"]),
      amount_cents: intent["amount"],
      currency: String.upcase(intent["currency"]),
      gateway_fee_cents: get_in(intent, ["charges", "data", Access.at(0), "application_fee_amount"])
    }
  end

  defp translate_status("succeeded"), do: :succeeded
  defp translate_status("requires_capture"), do: :pending
  defp translate_status(_), do: :failed

  defp translate_error(%{code: "card_declined"}), do: :card_declined
  defp translate_error(%{code: "insufficient_funds"}), do: :insufficient_funds
  defp translate_error(%{code: "expired_card"}), do: :expired_card
  defp translate_error(%{message: msg}), do: {:gateway_error, msg}
end
```

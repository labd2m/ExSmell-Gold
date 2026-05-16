# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Payments.Gateway.charge/3`, around the `opts[:capture]` and `opts[:idempotency_key]` usage
- **Affected function(s):** `charge/3`
- **Short explanation:** When `:capture` is `false` the function returns an authorization hold struct, when `true` it returns a charge receipt struct, and when `:return_raw` is set it returns the raw provider map — three entirely different shapes for what appears to be a single operation.

---

```elixir
defmodule Payments.Gateway do
  @moduledoc """
  Abstraction layer over payment provider APIs.
  Supports Stripe and Braintree as backends.
  """

  alias Payments.Repo
  alias Payments.Schema.{AuthorizationHold, ChargeReceipt}
  alias Payments.Providers.{Stripe, Braintree}

  require Logger

  @doc """
  Charges a payment method on behalf of a customer.

  ## Arguments

    * `customer_id` — Internal customer identifier.
    * `amount_cents` — Charge amount in cents.
    * `opts` — Keyword list of options.

  ## Options

    * `:payment_method_id` — ID of the stored payment method to charge.
    * `:currency` — ISO 4217 currency code. Defaults to `"USD"`.
    * `:capture` — When `false`, only authorizes the amount without
      capturing. Returns `%AuthorizationHold{}`. Defaults to `true`,
      which captures immediately and returns `%ChargeReceipt{}`.
    * `:return_raw` — When `true`, skips schema mapping and returns the
      raw provider response map directly.
    * `:provider` — `:stripe` (default) or `:braintree`.
    * `:idempotency_key` — Optional string for idempotent retries.

  ## Examples

      iex> charge(42, 5000)
      {:ok, %ChargeReceipt{id: "ch_abc", amount_cents: 5000, ...}}

      iex> charge(42, 5000, capture: false)
      {:ok, %AuthorizationHold{id: "auth_xyz", amount_cents: 5000, ...}}

      iex> charge(42, 5000, return_raw: true)
      {:ok, %{"id" => "ch_abc", "amount" => 5000, "status" => "succeeded", ...}}

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because the successful branch of the return
  # VALIDATION: yields either a %ChargeReceipt{}, a %AuthorizationHold{}, or
  # VALIDATION: a raw provider map depending on opts. These are structurally
  # VALIDATION: incompatible types that cannot be handled by a single
  # VALIDATION: pattern-match, forcing every caller to replicate option-checking.
  def charge(customer_id, amount_cents, opts \\ []) when is_integer(amount_cents) do
    currency = Keyword.get(opts, :currency, "USD")
    capture = Keyword.get(opts, :capture, true)
    provider = Keyword.get(opts, :provider, :stripe)
    payment_method_id = Keyword.fetch!(opts, :payment_method_id)
    idempotency_key = Keyword.get(opts, :idempotency_key)
    return_raw = Keyword.get(opts, :return_raw, false)

    provider_module = provider_module(provider)

    charge_params = %{
      amount: amount_cents,
      currency: currency,
      payment_method: payment_method_id,
      capture: capture,
      idempotency_key: idempotency_key
    }

    case provider_module.charge(charge_params) do
      {:ok, raw_response} when return_raw ->
        {:ok, raw_response}

      {:ok, raw_response} when not capture ->
        hold = persist_hold(customer_id, amount_cents, currency, raw_response, provider)
        {:ok, hold}

      {:ok, raw_response} ->
        receipt = persist_receipt(customer_id, amount_cents, currency, raw_response, provider)
        {:ok, receipt}

      {:error, %{code: code, message: message}} ->
        Logger.error("Payment failed for customer #{customer_id}: #{code} — #{message}")
        {:error, %{code: code, message: message}}
    end
  end
  # VALIDATION: SMELL END

  defp provider_module(:stripe), do: Stripe
  defp provider_module(:braintree), do: Braintree

  defp persist_receipt(customer_id, amount_cents, currency, raw, provider) do
    %ChargeReceipt{}
    |> ChargeReceipt.changeset(%{
      customer_id: customer_id,
      amount_cents: amount_cents,
      currency: currency,
      provider: provider,
      provider_charge_id: raw["id"],
      status: normalize_status(raw["status"]),
      charged_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp persist_hold(customer_id, amount_cents, currency, raw, provider) do
    %AuthorizationHold{}
    |> AuthorizationHold.changeset(%{
      customer_id: customer_id,
      amount_cents: amount_cents,
      currency: currency,
      provider: provider,
      provider_auth_id: raw["id"],
      expires_at: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
    })
    |> Repo.insert!()
  end

  defp normalize_status("succeeded"), do: :succeeded
  defp normalize_status("pending"), do: :pending
  defp normalize_status(_), do: :unknown

  @doc """
  Refunds a previously captured charge, fully or partially.
  """
  def refund(%ChargeReceipt{provider_charge_id: charge_id, provider: provider}, amount_cents) do
    provider_module = provider_module(provider)

    case provider_module.refund(charge_id, amount_cents) do
      {:ok, _raw} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```

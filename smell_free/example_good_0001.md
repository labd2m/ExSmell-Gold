# File: `example_good_01.md`

```elixir
defmodule Billing.Payments do
  @moduledoc """
  Context for managing payment records and processing charges
  within the billing domain.

  All mutations are transactional and return tagged tuples so callers
  can pattern-match on outcomes without using exception handling for
  ordinary control flow.
  """

  import Ecto.Query, warn: false

  alias Billing.Repo
  alias Billing.Payments.{Payment, PaymentMethod}
  alias Billing.Accounts.Customer

  @type charge_params :: %{
          required(:amount_cents) => pos_integer(),
          required(:currency) => String.t(),
          required(:description) => String.t()
        }

  @type payment_result :: {:ok, Payment.t()} | {:error, Ecto.Changeset.t() | atom()}

  @doc """
  Initiates a charge for a customer against a specific payment method.

  Validates the charge parameters, delegates to the payment gateway,
  and persists the result transactionally.

  Returns `{:ok, payment}` on success, or `{:error, reason}` on failure.
  """
  @spec charge(Customer.t(), PaymentMethod.t(), charge_params()) :: payment_result()
  def charge(%Customer{} = customer, %PaymentMethod{} = method, params)
      when is_map(params) do
    with {:ok, validated} <- validate_charge_params(params),
         {:ok, gateway_ref} <- authorize_with_gateway(customer, method, validated),
         {:ok, payment} <- persist_payment(customer, method, validated, gateway_ref) do
      {:ok, payment}
    end
  end

  @doc """
  Returns all successful payments for a customer, ordered by most recent first.
  """
  @spec list_successful(Customer.t()) :: [Payment.t()]
  def list_successful(%Customer{id: customer_id}) do
    Payment
    |> where([p], p.customer_id == ^customer_id and p.status == :succeeded)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  @doc """
  Retrieves a single payment record by its UUID.

  Returns `{:ok, payment}` if found, `{:error, :not_found}` otherwise.
  """
  @spec fetch(Ecto.UUID.t()) :: {:ok, Payment.t()} | {:error, :not_found}
  def fetch(payment_id) when is_binary(payment_id) do
    case Repo.get(Payment, payment_id) do
      nil -> {:error, :not_found}
      payment -> {:ok, payment}
    end
  end

  @doc """
  Issues a refund for a previously succeeded payment.

  Returns `{:ok, updated_payment}` or `{:error, reason}`.
  """
  @spec refund(Payment.t()) :: payment_result()
  def refund(%Payment{status: :succeeded} = payment) do
    payment
    |> Payment.refund_changeset(%{status: :refunded, refunded_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def refund(%Payment{}) do
    {:error, :not_refundable}
  end

  @doc """
  Computes the total amount charged to a customer in a given currency
  across all succeeded payments.
  """
  @spec total_charged(Customer.t(), String.t()) :: non_neg_integer()
  def total_charged(%Customer{id: customer_id}, currency) when is_binary(currency) do
    Payment
    |> where([p],
      p.customer_id == ^customer_id and
        p.currency == ^currency and
        p.status == :succeeded
    )
    |> select([p], sum(p.amount_cents))
    |> Repo.one()
    |> coerce_sum()
  end

  defp coerce_sum(nil), do: 0
  defp coerce_sum(total) when is_integer(total), do: total

  defp validate_charge_params(%{amount_cents: amt, currency: curr, description: desc})
       when is_integer(amt) and amt > 0 and
              is_binary(curr) and byte_size(curr) == 3 and
              is_binary(desc) and byte_size(desc) > 0 do
    {:ok, %{amount_cents: amt, currency: curr, description: desc}}
  end

  defp validate_charge_params(_params) do
    {:error, :invalid_params}
  end

  defp authorize_with_gateway(%Customer{gateway_id: gid}, %PaymentMethod{token: token}, params) do
    Billing.Gateway.authorize(gid, token, params.amount_cents, params.currency)
  end

  defp persist_payment(customer, method, params, gateway_ref) do
    %{
      customer_id: customer.id,
      payment_method_id: method.id,
      amount_cents: params.amount_cents,
      currency: params.currency,
      description: params.description,
      gateway_reference: gateway_ref,
      status: :succeeded
    }
    |> Payment.changeset()
    |> Repo.insert()
  end
end
```

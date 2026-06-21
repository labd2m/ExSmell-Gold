```elixir
defmodule Orders.CheckoutResult do
  @moduledoc """
  Carries the identifiers produced by a successful checkout pipeline run.
  """

  @type t :: %__MODULE__{
          order_id: String.t(),
          charge_id: String.t(),
          reservation_id: String.t(),
          confirmed_at: DateTime.t()
        }

  defstruct [:order_id, :charge_id, :reservation_id, :confirmed_at]

  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(order_id, charge_id, reservation_id) do
    %__MODULE__{
      order_id: order_id,
      charge_id: charge_id,
      reservation_id: reservation_id,
      confirmed_at: DateTime.utc_now()
    }
  end
end

defmodule Orders.CheckoutParams do
  @moduledoc false

  @type t :: %__MODULE__{
          customer_id: String.t(),
          cart_id: String.t(),
          payment_method_id: String.t(),
          shipping_address_id: String.t()
        }

  defstruct [:customer_id, :cart_id, :payment_method_id, :shipping_address_id]
end

defmodule Orders.Checkout do
  @moduledoc """
  Coordinates the multi-step checkout process for a customer order.

  The pipeline executes inventory reservation, payment authorisation,
  and order confirmation in sequence. When any step fails, previously
  completed steps are compensated before the error is surfaced to the
  caller. This keeps external systems consistent without relying on
  distributed transactions.
  """

  alias Orders.{CheckoutParams, CheckoutResult}
  alias Orders.Steps.{ConfirmOrder, ReserveInventory, AuthorisePayment}

  @type checkout_error ::
          {:error, :out_of_stock}
          | {:error, :payment_declined}
          | {:error, :confirmation_failed}

  @spec process(CheckoutParams.t()) ::
          {:ok, CheckoutResult.t()} | checkout_error()
  def process(%CheckoutParams{} = params) do
    with {:ok, reservation_id} <- ReserveInventory.run(params.cart_id),
         {:ok, charge_id} <- authorise_with_rollback(params, reservation_id),
         {:ok, order_id} <- confirm_with_rollback(params, reservation_id, charge_id) do
      {:ok, CheckoutResult.new(order_id, charge_id, reservation_id)}
    end
  end

  defp authorise_with_rollback(params, reservation_id) do
    case AuthorisePayment.run(params.payment_method_id, params.cart_id) do
      {:ok, charge_id} ->
        {:ok, charge_id}

      {:error, _reason} = err ->
        ReserveInventory.cancel(reservation_id)
        err
    end
  end

  defp confirm_with_rollback(params, reservation_id, charge_id) do
    case ConfirmOrder.run(params.customer_id, params.cart_id, reservation_id, charge_id) do
      {:ok, order_id} ->
        {:ok, order_id}

      {:error, _reason} = err ->
        AuthorisePayment.void(charge_id)
        ReserveInventory.cancel(reservation_id)
        err
    end
  end
end

defmodule Orders.Steps.ReserveInventory do
  @moduledoc false

  @spec run(String.t()) :: {:ok, String.t()} | {:error, :out_of_stock}
  def run(cart_id) when is_binary(cart_id) do
    {:ok, generate_id()}
  end

  @spec cancel(String.t()) :: :ok
  def cancel(reservation_id) when is_binary(reservation_id), do: :ok

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

defmodule Orders.Steps.AuthorisePayment do
  @moduledoc false

  @spec run(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :payment_declined}
  def run(payment_method_id, cart_id)
      when is_binary(payment_method_id) and is_binary(cart_id) do
    {:ok, generate_id()}
  end

  @spec void(String.t()) :: :ok
  def void(charge_id) when is_binary(charge_id), do: :ok

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

defmodule Orders.Steps.ConfirmOrder do
  @moduledoc false

  @spec run(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :confirmation_failed}
  def run(customer_id, cart_id, reservation_id, charge_id)
      when is_binary(customer_id) and is_binary(cart_id) and
             is_binary(reservation_id) and is_binary(charge_id) do
    {:ok, generate_id()}
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
```

```elixir
defmodule Payments.ChargeContext do
  @moduledoc """
  Executes payment charges with idempotency guarantees. A charge attempt
  with a given idempotency key always returns the same result regardless
  of how many times it is called, preventing double-charges on retries.
  """

  alias Payments.{Repo, Charge, IdempotencyRecord, GatewayClient}
  alias Ecto.Multi

  @type charge_params :: %{
          amount_cents: pos_integer(),
          currency: String.t(),
          customer_id: String.t(),
          payment_method_id: String.t(),
          description: String.t()
        }

  @type charge_result :: {:ok, Charge.t()} | {:error, atom() | Ecto.Changeset.t()}

  @spec charge(charge_params(), String.t()) :: charge_result()
  def charge(params, idempotency_key) when is_binary(idempotency_key) and is_map(params) do
    case lookup_idempotent_result(idempotency_key) do
      {:cached, charge} -> {:ok, charge}
      :not_found -> perform_charge(params, idempotency_key)
    end
  end

  @spec refund(Charge.t(), pos_integer() | nil) :: charge_result()
  def refund(%Charge{} = charge, amount_cents \\ nil) do
    refund_amount = amount_cents || charge.amount_cents

    with :ok <- validate_refundable(charge, refund_amount),
         {:ok, gateway_refund} <- GatewayClient.refund(charge.gateway_charge_id, refund_amount) do
      record_refund(charge, gateway_refund, refund_amount)
    end
  end

  @spec get_charge(String.t()) :: {:ok, Charge.t()} | {:error, :not_found}
  def get_charge(charge_id) when is_binary(charge_id) do
    case Repo.get(Charge, charge_id) do
      nil -> {:error, :not_found}
      charge -> {:ok, charge}
    end
  end

  @spec perform_charge(charge_params(), String.t()) :: charge_result()
  defp perform_charge(params, idempotency_key) do
    Multi.new()
    |> Multi.run(:gateway, fn _repo, _ -> GatewayClient.charge(params) end)
    |> Multi.insert(:charge, fn %{gateway: gw_charge} ->
      Charge.creation_changeset(%Charge{}, %{
        amount_cents: params.amount_cents,
        currency: params.currency,
        customer_id: params.customer_id,
        payment_method_id: params.payment_method_id,
        description: params.description,
        gateway_charge_id: gw_charge.id,
        status: :succeeded
      })
    end)
    |> Multi.insert(:idempotency, fn %{charge: charge} ->
      IdempotencyRecord.creation_changeset(%IdempotencyRecord{}, %{
        key: idempotency_key,
        charge_id: charge.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{charge: charge}} -> {:ok, charge}
      {:error, :gateway, reason, _} -> {:error, reason}
      {:error, :charge, changeset, _} -> {:error, changeset}
      {:error, :idempotency, _changeset, %{charge: charge}} -> {:ok, charge}
    end
  end

  @spec lookup_idempotent_result(String.t()) :: {:cached, Charge.t()} | :not_found
  defp lookup_idempotent_result(key) do
    case Repo.get_by(IdempotencyRecord, key: key) do
      nil -> :not_found
      record -> {:cached, Repo.get!(Charge, record.charge_id)}
    end
  end

  @spec validate_refundable(Charge.t(), pos_integer()) :: :ok | {:error, atom()}
  defp validate_refundable(charge, amount) do
    cond do
      charge.status != :succeeded -> {:error, :charge_not_refundable}
      amount > charge.amount_cents -> {:error, :refund_exceeds_charge}
      true -> :ok
    end
  end

  @spec record_refund(Charge.t(), map(), pos_integer()) :: charge_result()
  defp record_refund(charge, gateway_refund, amount_cents) do
    charge
    |> Charge.refund_changeset(%{
      status: :refunded,
      refund_id: gateway_refund.id,
      refunded_amount_cents: amount_cents,
      refunded_at: DateTime.utc_now()
    })
    |> Repo.update()
  end
end
```

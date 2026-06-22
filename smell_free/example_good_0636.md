```elixir
defmodule Payments.RefundContext do
  @moduledoc """
  Manages payment refunds with idempotency and partial-refund support.
  Each refund references the original charge, carries its own idempotency
  key, and is persisted before the gateway call so a crash between the
  two operations is recoverable. The gateway is called at most once per
  unique idempotency key.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Payments.{Refund, Charge}
  alias Payments.GatewayClient

  @type charge_id :: Ecto.UUID.t()
  @type amount_cents :: pos_integer()
  @type idempotency_key :: String.t()

  @type refund_result ::
          {:ok, Refund.t()}
          | {:error,
             :charge_not_found
             | :already_fully_refunded
             | :amount_exceeds_refundable
             | :duplicate_idempotency_key
             | :gateway_failed
             | Ecto.Changeset.t()}

  @doc """
  Issues a refund of `amount_cents` against `charge_id`. Uses
  `idempotency_key` to prevent duplicate gateway calls on retry.
  """
  @spec issue(charge_id(), amount_cents(), idempotency_key()) :: refund_result()
  def issue(charge_id, amount_cents, idempotency_key)
      when is_binary(charge_id) and is_integer(amount_cents) and amount_cents > 0
      and is_binary(idempotency_key) do
    Repo.transaction(fn ->
      with {:ok, charge} <- fetch_charge(charge_id),
           :ok <- check_refundable(charge, amount_cents),
           :ok <- check_idempotency(idempotency_key) do
        attrs = %{charge_id: charge_id, amount_cents: amount_cents,
                  idempotency_key: idempotency_key, status: "pending"}

        case %Refund{} |> Refund.changeset(attrs) |> Repo.insert() do
          {:ok, refund} ->
            finalise_refund(refund, charge)

          {:error, cs} ->
            Repo.rollback(cs)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Returns all refunds associated with `charge_id`."
  @spec refunds_for(charge_id()) :: [Refund.t()]
  def refunds_for(charge_id) when is_binary(charge_id) do
    Refund
    |> where([r], r.charge_id == ^charge_id)
    |> order_by([r], asc: r.inserted_at)
    |> Repo.all()
  end

  @doc "Returns the total refunded amount in cents for `charge_id`."
  @spec total_refunded(charge_id()) :: non_neg_integer()
  def total_refunded(charge_id) when is_binary(charge_id) do
    from(r in Refund,
      where: r.charge_id == ^charge_id and r.status == "succeeded",
      select: sum(r.amount_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp fetch_charge(charge_id) do
    case Repo.get(Charge, charge_id) do
      nil -> {:error, :charge_not_found}
      charge -> {:ok, charge}
    end
  end

  defp check_refundable(%Charge{amount_cents: charged} = charge, amount_cents) do
    already = total_refunded(charge.id)
    refundable = charged - already

    cond do
      refundable == 0 -> {:error, :already_fully_refunded}
      amount_cents > refundable -> {:error, :amount_exceeds_refundable}
      true -> :ok
    end
  end

  defp check_idempotency(key) do
    if Repo.exists?(from(r in Refund, where: r.idempotency_key == ^key)) do
      {:error, :duplicate_idempotency_key}
    else
      :ok
    end
  end

  defp finalise_refund(refund, charge) do
    gateway_ref = charge.gateway_charge_id

    case GatewayClient.charge(%{
      amount_cents: refund.amount_cents,
      currency: charge.currency,
      source_token: gateway_ref,
      idempotency_key: refund.idempotency_key
    }) do
      {:ok, result} ->
        refund
        |> Refund.gateway_result_changeset(%{status: "succeeded", gateway_refund_id: result.charge_id})
        |> Repo.update!()

      {:error, _reason} ->
        refund
        |> Refund.gateway_result_changeset(%{status: "failed"})
        |> Repo.update!()
        Repo.rollback(:gateway_failed)
    end
  end
end
```

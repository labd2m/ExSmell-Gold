```elixir
defmodule MyApp.Payments.SplitCharge do
  @moduledoc """
  Coordinates split payments where a single order amount is charged
  across multiple payment methods in sequence. Each payment method is
  charged for up to its configured limit; if the first method covers
  the full amount the remaining methods are not contacted.

  Partial failures (first method succeeds, second fails) trigger a
  refund of already-captured amounts before returning the error, leaving
  no unaccounted charges.
  """

  alias MyApp.Payments.Gateway

  @type payment_method :: %{
          required(:id) => String.t(),
          required(:limit_cents) => pos_integer() | :unlimited,
          optional(:label) => String.t()
        }

  @type charge_result :: %{
          method_id: String.t(),
          charged_cents: pos_integer(),
          charge_id: String.t()
        }

  @type split_result :: %{
          total_charged_cents: pos_integer(),
          charges: [charge_result()]
        }

  @doc """
  Charges `total_cents` across `payment_methods` in order. Each method
  is charged for up to its stated limit. Returns `{:ok, result}` when
  the full amount is collected, or `{:error, :insufficient_payment_methods}`
  when combined limits fall short of the total.
  """
  @spec charge(pos_integer(), [payment_method()], String.t()) ::
          {:ok, split_result()} | {:error, :insufficient_payment_methods} | {:error, term()}
  def charge(total_cents, payment_methods, idempotency_prefix)
      when is_integer(total_cents) and total_cents > 0 do
    if coverable?(total_cents, payment_methods) do
      run_split_charge(total_cents, payment_methods, idempotency_prefix)
    else
      {:error, :insufficient_payment_methods}
    end
  end

  @spec run_split_charge(pos_integer(), [payment_method()], String.t()) ::
          {:ok, split_result()} | {:error, term()}
  defp run_split_charge(total_cents, payment_methods, idempotency_prefix) do
    {charges, _remaining} =
      Enum.reduce_while(payment_methods, {[], total_cents}, fn method, {acc, remaining} ->
        if remaining <= 0 do
          {:halt, {acc, 0}}
        else
          amount = charge_amount(method, remaining)
          key = "#{idempotency_prefix}_#{method.id}"

          case Gateway.charge(method.id, amount, key) do
            {:ok, charge_id} ->
              result = %{method_id: method.id, charged_cents: amount, charge_id: charge_id}
              {:cont, {[result | acc], remaining - amount}}

            {:error, reason} ->
              {:halt, {:error, reason, Enum.reverse(acc)}}
          end
        end
      end)

    case charges do
      {:error, reason, partial_charges} ->
        refund_partial(partial_charges)
        {:error, reason}

      charges ->
        total = Enum.sum_by(charges, & &1.charged_cents)
        {:ok, %{total_charged_cents: total, charges: Enum.reverse(charges)}}
    end
  end

  @spec coverable?(pos_integer(), [payment_method()]) :: boolean()
  defp coverable?(total_cents, methods) do
    if Enum.any?(methods, &(&1.limit_cents == :unlimited)) do
      true
    else
      total_limit = Enum.sum_by(methods, & &1.limit_cents)
      total_limit >= total_cents
    end
  end

  @spec charge_amount(payment_method(), pos_integer()) :: pos_integer()
  defp charge_amount(%{limit_cents: :unlimited}, remaining), do: remaining
  defp charge_amount(%{limit_cents: limit}, remaining), do: min(limit, remaining)

  @spec refund_partial([charge_result()]) :: :ok
  defp refund_partial(charges) do
    Enum.each(charges, fn charge ->
      Gateway.refund(charge.charge_id, charge.charged_cents)
    end)
  end
end
```

```elixir
defmodule MyApp.Commerce.AbandonedCartReclaimer do
  @moduledoc """
  Identifies carts that have been idle for longer than a configurable
  threshold and, based on customer history, decides whether to offer a
  discount incentive. Decisions are recorded so that the same cart is
  not contacted more than once per abandonment event and the offer rate
  can be analysed in the reporting system.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Commerce.{Cart, CartRecoveryRecord}
  alias MyApp.Workers.RecoveryEmailWorker

  @idle_hours 2
  @discount_threshold_orders 3
  @discount_bps 1_000

  @type reclaim_summary :: %{
          evaluated: non_neg_integer(),
          with_incentive: non_neg_integer(),
          without_incentive: non_neg_integer(),
          already_contacted: non_neg_integer()
        }

  @doc """
  Evaluates all idle carts and schedules recovery jobs. Returns a
  summary of the evaluation run.
  """
  @spec run() :: reclaim_summary()
  def run do
    idle_carts = fetch_idle_carts()

    Enum.reduce(idle_carts, initial_summary(), fn cart, acc ->
      process_cart(cart, acc)
    end)
  end

  @spec process_cart(Cart.t(), reclaim_summary()) :: reclaim_summary()
  defp process_cart(cart, acc) do
    if already_contacted?(cart) do
      %{acc | already_contacted: acc.already_contacted + 1}
    else
      schedule_recovery(cart)
      update_summary(acc, cart)
    end
  end

  @spec schedule_recovery(Cart.t()) :: :ok
  defp schedule_recovery(cart) do
    past_orders = count_past_orders(cart.customer_id)
    offer_discount = past_orders >= @discount_threshold_orders
    discount_bps = if offer_discount, do: @discount_bps, else: 0

    %{
      cart_id: cart.id,
      customer_id: cart.customer_id,
      email: cart.customer_email,
      discount_bps: discount_bps
    }
    |> RecoveryEmailWorker.new()
    |> Oban.insert()

    record_contact(cart.id, offer_discount)
  end

  @spec update_summary(reclaim_summary(), Cart.t()) :: reclaim_summary()
  defp update_summary(acc, cart) do
    if count_past_orders(cart.customer_id) >= @discount_threshold_orders do
      %{acc | with_incentive: acc.with_incentive + 1}
    else
      %{acc | without_incentive: acc.without_incentive + 1}
    end
  end

  @spec fetch_idle_carts() :: [Cart.t()]
  defp fetch_idle_carts do
    cutoff = DateTime.add(DateTime.utc_now(), -@idle_hours, :hour)

    Cart
    |> where([c], is_nil(c.converted_at) and c.updated_at < ^cutoff)
    |> where([c], not is_nil(c.customer_email) and c.item_count > 0)
    |> Repo.all()
  end

  @spec already_contacted?(Cart.t()) :: boolean()
  defp already_contacted?(cart) do
    CartRecoveryRecord
    |> where([r], r.cart_id == ^cart.id)
    |> Repo.exists?()
  end

  @spec count_past_orders(String.t() | nil) :: non_neg_integer()
  defp count_past_orders(nil), do: 0

  defp count_past_orders(customer_id) do
    MyApp.Commerce.Order
    |> where([o], o.customer_id == ^customer_id and o.status == :completed)
    |> select([o], count(o.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @spec record_contact(String.t(), boolean()) :: :ok
  defp record_contact(cart_id, offered_discount) do
    %CartRecoveryRecord{}
    |> CartRecoveryRecord.changeset(%{
      cart_id: cart_id,
      discount_offered: offered_discount,
      contacted_at: DateTime.utc_now()
    })
    |> Repo.insert()

    :ok
  end

  @spec initial_summary() :: reclaim_summary()
  defp initial_summary do
    %{evaluated: 0, with_incentive: 0, without_incentive: 0, already_contacted: 0}
  end
end
```

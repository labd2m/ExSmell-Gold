```elixir
defmodule Loyalty.Rewards do
  @moduledoc """
  Handles reward redemptions for the loyalty programme, including
  point balance validation, fulfilment routing, and member notifications.
  """

  require Logger

  alias Loyalty.Repo
  alias Loyalty.Schemas.Redemption
  alias Loyalty.Schemas.PointTransaction
  alias Loyalty.PointsLedger
  alias Loyalty.FulfillmentRouter
  alias Loyalty.Mailer

  @valid_tiers ~w(bronze silver gold platinum)
  @valid_delivery_methods ~w(digital postal store_pickup)

  def redeem_reward(
        member_id,
        member_email,
        tier,
        reward_id,
        reward_name,
        points_cost,
        delivery_method,
        delivery_address,
        notes,
        notify_member
      ) do
    with :ok <- validate_tier(tier),
         :ok <- validate_delivery(delivery_method, delivery_address),
         :ok <- validate_points_cost(points_cost) do
      balance = PointsLedger.current_balance(member_id)

      if balance < points_cost do
        Logger.warn("Insufficient points for member #{member_id}: need #{points_cost}, have #{balance}")
        {:error, {:insufficient_points, balance}}
      else
        redemption_attrs = %{
          member_id: member_id,
          member_email: member_email,
          tier: tier,
          reward_id: reward_id,
          reward_name: reward_name,
          points_cost: points_cost,
          delivery_method: delivery_method,
          delivery_address: delivery_address,
          notes: notes,
          status: :pending,
          inserted_at: DateTime.utc_now()
        }

        Repo.transaction(fn ->
          case Repo.insert(Redemption.changeset(%Redemption{}, redemption_attrs)) do
            {:ok, redemption} ->
              transaction_attrs = %{
                member_id: member_id,
                redemption_id: redemption.id,
                type: :debit,
                points: -points_cost,
                balance_after: balance - points_cost,
                description: "Redeemed: #{reward_name}",
                occurred_at: DateTime.utc_now()
              }

              {:ok, _} =
                Repo.insert(PointTransaction.changeset(%PointTransaction{}, transaction_attrs))

              FulfillmentRouter.dispatch(delivery_method, %{
                redemption_id: redemption.id,
                reward_id: reward_id,
                address: delivery_address
              })

              if notify_member do
                Mailer.send_redemption_confirmation(member_email, redemption)
              end

              Logger.info("Reward #{reward_id} redeemed by member #{member_id}, cost=#{points_cost}pts")
              redemption

            {:error, changeset} ->
              Logger.error("Redemption failed: #{inspect(changeset.errors)}")
              Repo.rollback(:redemption_failed)
          end
        end)
      end
    end
  end

  defp validate_tier(t) when t in @valid_tiers, do: :ok
  defp validate_tier(t), do: {:error, {:unknown_tier, t}}

  defp validate_delivery(method, address) do
    cond do
      method not in @valid_delivery_methods ->
        {:error, {:unknown_delivery_method, method}}

      method == "postal" and (is_nil(address) or String.trim(address) == "") ->
        {:error, :missing_delivery_address}

      true ->
        :ok
    end
  end

  defp validate_points_cost(cost) when is_integer(cost) and cost > 0, do: :ok
  defp validate_points_cost(_), do: {:error, :invalid_points_cost}
end
```

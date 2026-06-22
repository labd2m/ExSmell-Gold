```elixir
defmodule Commerce.LoyaltyPointsContext do
  @moduledoc """
  Manages a customer loyalty points programme. Points are earned on
  qualifying purchases and redeemed for order discounts. Each transaction
  is recorded in an append-only ledger. Points expire after a configurable
  window; expired points are excluded from the available balance.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Commerce.{LoyaltyTransaction, Order}

  @type customer_id :: String.t()
  @type points :: pos_integer()
  @type earn_reason :: :purchase | :referral | :bonus | :adjustment
  @type redeem_reason :: :order_discount | :manual_redemption

  @default_expiry_days 365
  @points_per_dollar 10

  @doc "Awards `points` to `customer_id` for the given `reason`."
  @spec award(customer_id(), points(), earn_reason(), String.t()) ::
          {:ok, LoyaltyTransaction.t()} | {:error, Ecto.Changeset.t()}
  def award(customer_id, points, reason, reference)
      when is_binary(customer_id) and is_integer(points) and points > 0 do
    expires_at = DateTime.add(DateTime.utc_now(), @default_expiry_days * 86_400, :second)
    attrs = %{customer_id: customer_id, delta: points, reason: Atom.to_string(reason),
              reference: reference, expires_at: expires_at}
    %LoyaltyTransaction{} |> LoyaltyTransaction.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Computes points earned for `order` and awards them. Uses the base
  dollar-to-points conversion rate.
  """
  @spec award_for_order(Order.t()) :: {:ok, LoyaltyTransaction.t()} | {:error, term()}
  def award_for_order(%Order{id: id, customer_id: cid, total_cents: total}) do
    earned = div(total, 100) * @points_per_dollar
    if earned > 0 do
      award(cid, earned, :purchase, "order_#{id}")
    else
      {:ok, nil}
    end
  end

  @doc """
  Redeems `points` from `customer_id`'s balance. Returns
  `{:error, :insufficient_points}` when the balance is too low.
  """
  @spec redeem(customer_id(), points(), redeem_reason(), String.t()) ::
          {:ok, LoyaltyTransaction.t()} | {:error, :insufficient_points | Ecto.Changeset.t()}
  def redeem(customer_id, points, reason, reference)
      when is_binary(customer_id) and is_integer(points) and points > 0 do
    Repo.transaction(fn ->
      available = balance(customer_id)

      if available < points do
        Repo.rollback(:insufficient_points)
      else
        attrs = %{customer_id: customer_id, delta: -points, reason: Atom.to_string(reason),
                  reference: reference, expires_at: nil}

        case %LoyaltyTransaction{} |> LoyaltyTransaction.changeset(attrs) |> Repo.insert() do
          {:ok, txn} -> txn
          {:error, cs} -> Repo.rollback(cs)
        end
      end
    end)
  end

  @doc "Returns the current non-expired points balance for `customer_id`."
  @spec balance(customer_id()) :: non_neg_integer()
  def balance(customer_id) when is_binary(customer_id) do
    now = DateTime.utc_now()

    result =
      from(t in LoyaltyTransaction,
        where: t.customer_id == ^customer_id
               and (is_nil(t.expires_at) or t.expires_at > ^now),
        select: sum(t.delta)
      )
      |> Repo.one()

    max(0, result || 0)
  end

  @doc "Returns the transaction history for `customer_id` in reverse order."
  @spec history(customer_id(), pos_integer()) :: [LoyaltyTransaction.t()]
  def history(customer_id, limit \\ 50) when is_binary(customer_id) do
    from(t in LoyaltyTransaction,
      where: t.customer_id == ^customer_id,
      order_by: [desc: t.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Returns the dollar value of `points` using the current conversion rate."
  @spec points_to_cents(points()) :: non_neg_integer()
  def points_to_cents(points) when is_integer(points) and points >= 0 do
    div(points * 100, @points_per_dollar)
  end
end
```

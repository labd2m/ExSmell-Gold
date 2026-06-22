# File: `example_good_617.md`

```elixir
defmodule Commerce.LoyaltyPoints do
  @moduledoc """
  Manages a double-entry loyalty points ledger for customer reward
  programs. Points are earned on purchases, redeemed against orders,
  and expire after a configurable period.

  All mutations go through Ecto transactions to ensure the ledger
  stays balanced. Expired points are excluded from balance calculations
  without requiring batch deletion jobs.
  """

  import Ecto.Query, warn: false

  alias Commerce.{LoyaltyLedgerEntry, Repo}
  alias Accounts.Customer

  @type customer_id :: Ecto.UUID.t()
  @type points :: non_neg_integer()
  @type entry_type :: :earn | :redeem | :expire | :adjust
  @type point_result :: {:ok, LoyaltyLedgerEntry.t()} | {:error, Ecto.Changeset.t() | atom()}

  @doc """
  Records points earned by a customer from a purchase.

  Returns `{:ok, ledger_entry}`.
  """
  @spec earn(customer_id(), points(), String.t(), keyword()) :: point_result()
  def earn(customer_id, points, reference, opts \\ [])
      when is_binary(customer_id) and is_integer(points) and points > 0 do
    expires_on = Keyword.get(opts, :expires_on)

    insert_entry(customer_id, :earn, points, reference, expires_on)
  end

  @doc """
  Redeems points from a customer's balance toward a purchase.

  Returns `{:error, :insufficient_balance}` when the customer does not
  have enough unexpired points.
  """
  @spec redeem(customer_id(), points(), String.t()) :: point_result()
  def redeem(customer_id, points, reference)
      when is_binary(customer_id) and is_integer(points) and points > 0 do
    balance = current_balance(customer_id)

    if balance >= points do
      insert_entry(customer_id, :redeem, -points, reference, nil)
    else
      {:error, :insufficient_balance}
    end
  end

  @doc """
  Returns the current unexpired point balance for a customer.
  """
  @spec current_balance(customer_id()) :: non_neg_integer()
  def current_balance(customer_id) when is_binary(customer_id) do
    today = Date.utc_today()

    LoyaltyLedgerEntry
    |> where([e], e.customer_id == ^customer_id)
    |> where([e], is_nil(e.expires_on) or e.expires_on >= ^today)
    |> select([e], sum(e.points_delta))
    |> Repo.one()
    |> case do
      nil -> 0
      total -> max(total, 0)
    end
  end

  @doc """
  Returns a ledger summary for a customer: earned, redeemed, expired,
  and current balance.
  """
  @spec summary(customer_id()) :: map()
  def summary(customer_id) when is_binary(customer_id) do
    entries =
      LoyaltyLedgerEntry
      |> where([e], e.customer_id == ^customer_id)
      |> Repo.all()

    earned = entries |> Enum.filter(&(&1.entry_type == :earn)) |> Enum.sum_by(& &1.points_delta)
    redeemed = entries |> Enum.filter(&(&1.entry_type == :redeem)) |> Enum.sum_by(& abs(&1.points_delta))
    expired = entries |> Enum.filter(&(&1.entry_type == :expire)) |> Enum.sum_by(& abs(&1.points_delta))

    %{
      earned: earned,
      redeemed: redeemed,
      expired: expired,
      balance: current_balance(customer_id)
    }
  end

  @doc """
  Expires all points for a customer that have passed their expiry date
  by recording offsetting ledger entries.

  Returns the number of expiry entries created.
  """
  @spec expire_stale(customer_id()) :: {:ok, non_neg_integer()}
  def expire_stale(customer_id) when is_binary(customer_id) do
    today = Date.utc_today()

    expirable =
      LoyaltyLedgerEntry
      |> where([e], e.customer_id == ^customer_id and e.entry_type == :earn)
      |> where([e], not is_nil(e.expires_on) and e.expires_on < ^today)
      |> Repo.all()

    count =
      Enum.reduce(expirable, 0, fn entry, acc ->
        still_valid = remaining_value(entry.id)

        if still_valid > 0 do
          insert_entry(customer_id, :expire, -still_valid, "expired:#{entry.id}", nil)
          acc + 1
        else
          acc
        end
      end)

    {:ok, count}
  end

  defp remaining_value(earn_entry_id) do
    offset =
      LoyaltyLedgerEntry
      |> where([e], e.source_entry_id == ^earn_entry_id)
      |> select([e], sum(e.points_delta))
      |> Repo.one()

    max(0, -(offset || 0))
  end

  defp insert_entry(customer_id, type, delta, reference, expires_on) do
    %{
      customer_id: customer_id,
      entry_type: type,
      points_delta: delta,
      reference: reference,
      expires_on: expires_on
    }
    |> LoyaltyLedgerEntry.changeset()
    |> Repo.insert()
  end
end
```

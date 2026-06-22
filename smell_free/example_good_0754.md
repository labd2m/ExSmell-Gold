```elixir
defmodule MyApp.Retail.LoyaltyLedger do
  @moduledoc """
  Manages a customer's loyalty point balance using an append-only ledger
  pattern. Points are earned on purchases, redeemed against orders, and
  may expire after a configurable period. The current balance is always
  derived from the ledger rather than stored as a mutable column,
  ensuring perfect auditability and correctness under concurrent writes.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Retail.LoyaltyEntry

  @points_per_cent 1
  @expiry_days 365

  @type customer_id :: String.t()
  @type entry_type :: :earned | :redeemed | :expired | :adjusted

  @type entry :: %{
          required(:customer_id) => customer_id(),
          required(:type) => entry_type(),
          required(:points) => integer(),
          optional(:reference_id) => String.t(),
          optional(:note) => String.t()
        }

  @doc """
  Records points earned from an order. Points are calculated from the
  order total in cents using the standard earn rate.
  """
  @spec earn(customer_id(), pos_integer(), String.t()) ::
          {:ok, LoyaltyEntry.t()} | {:error, Ecto.Changeset.t()}
  def earn(customer_id, order_total_cents, order_id)
      when is_binary(customer_id) and is_integer(order_total_cents) do
    points = div(order_total_cents, 100) * @points_per_cent
    expires_at = Date.add(Date.utc_today(), @expiry_days)

    insert_entry(%{
      customer_id: customer_id,
      type: :earned,
      points: points,
      reference_id: order_id,
      expires_at: expires_at
    })
  end

  @doc """
  Redeems `points` from `customer_id`'s balance toward `order_id`.
  Returns `{:error, :insufficient_balance}` when the balance is too low.
  """
  @spec redeem(customer_id(), pos_integer(), String.t()) ::
          {:ok, LoyaltyEntry.t()} | {:error, :insufficient_balance} | {:error, Ecto.Changeset.t()}
  def redeem(customer_id, points, order_id)
      when is_binary(customer_id) and is_integer(points) and points > 0 do
    if balance(customer_id) >= points do
      insert_entry(%{
        customer_id: customer_id,
        type: :redeemed,
        points: -points,
        reference_id: order_id
      })
    else
      {:error, :insufficient_balance}
    end
  end

  @doc """
  Applies a manual adjustment (positive or negative) to `customer_id`'s
  balance with an operator note.
  """
  @spec adjust(customer_id(), integer(), String.t()) ::
          {:ok, LoyaltyEntry.t()} | {:error, Ecto.Changeset.t()}
  def adjust(customer_id, points, note)
      when is_binary(customer_id) and is_integer(points) and is_binary(note) do
    insert_entry(%{customer_id: customer_id, type: :adjusted, points: points, note: note})
  end

  @doc "Returns the current active point balance for `customer_id`."
  @spec balance(customer_id()) :: integer()
  def balance(customer_id) when is_binary(customer_id) do
    today = Date.utc_today()

    LoyaltyEntry
    |> where([e], e.customer_id == ^customer_id)
    |> where([e], is_nil(e.expires_at) or e.expires_at >= ^today)
    |> select([e], sum(e.points))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Returns the complete point history for `customer_id`, newest first."
  @spec history(customer_id()) :: [LoyaltyEntry.t()]
  def history(customer_id) when is_binary(customer_id) do
    LoyaltyEntry
    |> where([e], e.customer_id == ^customer_id)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  @doc "Expires all entries for `customer_id` whose `expires_at` has passed."
  @spec expire_stale(customer_id()) :: non_neg_integer()
  def expire_stale(customer_id) when is_binary(customer_id) do
    today = Date.utc_today()

    stale_points =
      LoyaltyEntry
      |> where([e], e.customer_id == ^customer_id and e.type == :earned)
      |> where([e], not is_nil(e.expires_at) and e.expires_at < ^today)
      |> select([e], sum(e.points))
      |> Repo.one()
      |> Kernel.||(0)

    if stale_points > 0 do
      insert_entry(%{customer_id: customer_id, type: :expired, points: -stale_points})
    end

    max(stale_points, 0)
  end

  @spec insert_entry(map()) :: {:ok, LoyaltyEntry.t()} | {:error, Ecto.Changeset.t()}
  defp insert_entry(attrs) do
    %LoyaltyEntry{}
    |> LoyaltyEntry.changeset(attrs)
    |> Repo.insert()
  end
end
```

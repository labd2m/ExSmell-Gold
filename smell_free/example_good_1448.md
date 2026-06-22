```elixir
defmodule MyApp.Commerce.GiftCardRedemption do
  @moduledoc """
  Handles gift card balance lookups and redemptions. Gift cards carry a
  redemption code and a balance stored in the `gift_cards` table. Each
  redemption is recorded as a ledger-style debit entry so the full
  redemption history is preserved. Concurrent redemptions are serialised
  with a row-level lock to prevent balance overdraft.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Commerce.{GiftCard, GiftCardLedgerEntry}

  @type redemption_code :: String.t()

  @doc "Returns the current available balance for `code`, or `nil` when not found."
  @spec balance(redemption_code()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def balance(code) when is_binary(code) do
    case fetch_active(code) do
      nil -> {:error, :not_found}
      card -> {:ok, card.balance_cents}
    end
  end

  @doc """
  Redeems up to `amount_cents` from the gift card identified by `code`
  toward `order_id`. Returns the amount actually redeemed (which may be
  less than `amount_cents` if the balance is insufficient).
  """
  @spec redeem(redemption_code(), pos_integer(), String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :not_found}
          | {:error, :exhausted}
          | {:error, term()}
  def redeem(code, amount_cents, order_id)
      when is_binary(code) and is_integer(amount_cents) and amount_cents > 0 do
    Repo.transaction(fn ->
      card =
        GiftCard
        |> where([g], g.code == ^code and g.active == true)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case card do
        nil ->
          Repo.rollback(:not_found)

        %GiftCard{balance_cents: 0} ->
          Repo.rollback(:exhausted)

        card ->
          redeemed = min(card.balance_cents, amount_cents)
          new_balance = card.balance_cents - redeemed

          card
          |> GiftCard.changeset(%{balance_cents: new_balance})
          |> Repo.update!()

          %GiftCardLedgerEntry{}
          |> GiftCardLedgerEntry.changeset(%{
            gift_card_id: card.id,
            order_id: order_id,
            amount_cents: -redeemed,
            occurred_at: DateTime.utc_now()
          })
          |> Repo.insert!()

          redeemed
      end
    end)
    |> case do
      {:ok, redeemed} -> {:ok, redeemed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the full redemption history for a gift card."
  @spec history(redemption_code()) :: [GiftCardLedgerEntry.t()] | {:error, :not_found}
  def history(code) when is_binary(code) do
    case Repo.get_by(GiftCard, code: code) do
      nil ->
        {:error, :not_found}

      card ->
        GiftCardLedgerEntry
        |> where([e], e.gift_card_id == ^card.id)
        |> order_by([e], desc: e.occurred_at)
        |> Repo.all()
    end
  end

  @spec fetch_active(redemption_code()) :: GiftCard.t() | nil
  defp fetch_active(code) do
    Repo.get_by(GiftCard, code: code, active: true)
  end
end
```

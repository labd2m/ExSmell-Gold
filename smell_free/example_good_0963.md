# File: `example_good_963.md`

```elixir
defmodule Commerce.GiftCardManager do
  @moduledoc """
  Manages the full lifecycle of gift cards: issuance, balance queries,
  partial and full redemptions, and expiry enforcement.

  Gift card codes are randomly generated and stored as hashes. The
  plaintext code is returned once at issuance and not retrievable
  thereafter. All balance mutations are recorded as ledger entries
  for a complete audit trail.
  """

  import Ecto.Query, warn: false

  alias Commerce.{GiftCard, GiftCardLedgerEntry, Repo}

  @code_bytes 12
  @code_prefix "GC"

  @type code :: String.t()
  @type amount_cents :: non_neg_integer()

  @type issue_result ::
          {:ok, %{code: code(), gift_card: GiftCard.t()}}
          | {:error, Ecto.Changeset.t()}

  @type redeem_result ::
          {:ok, %{redeemed_cents: amount_cents(), remaining_cents: amount_cents()}}
          | {:error, :invalid_code | :card_expired | :insufficient_balance | :zero_amount}

  @doc """
  Issues a new gift card with an initial balance.

  Returns `{:ok, %{code: plaintext_code, gift_card: record}}`. The
  plaintext code is the only time it can be retrieved.
  """
  @spec issue(amount_cents(), Date.t() | nil) :: issue_result()
  def issue(initial_balance_cents, expires_on \\ nil)
      when is_integer(initial_balance_cents) and initial_balance_cents > 0 do
    plaintext = generate_code()
    code_hash = hash(plaintext)

    Repo.transaction(fn ->
      gift_card =
        %{code_hash: code_hash, expires_on: expires_on, active: true}
        |> GiftCard.changeset()
        |> Repo.insert!()

      %{gift_card_id: gift_card.id, delta_cents: initial_balance_cents, entry_type: :issue}
      |> GiftCardLedgerEntry.changeset()
      |> Repo.insert!()

      %{code: plaintext, gift_card: gift_card}
    end)
  end

  @doc """
  Returns the current balance for a gift card identified by plaintext `code`.

  Returns `{:ok, balance_cents}` or `{:error, :invalid_code | :card_expired}`.
  """
  @spec balance(code()) :: {:ok, amount_cents()} | {:error, :invalid_code | :card_expired}
  def balance(code) when is_binary(code) do
    case find_card(code) do
      {:ok, card} -> {:ok, compute_balance(card.id)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Redeems up to `requested_cents` from a gift card.

  When `requested_cents` exceeds the available balance, only the
  available balance is redeemed. Returns the actual amount redeemed
  and the remaining balance.
  """
  @spec redeem(code(), amount_cents()) :: redeem_result()
  def redeem(_code, 0), do: {:error, :zero_amount}

  def redeem(code, requested_cents)
      when is_binary(code) and is_integer(requested_cents) and requested_cents > 0 do
    with {:ok, card} <- find_card(code) do
      current_balance = compute_balance(card.id)

      if current_balance == 0 do
        {:error, :insufficient_balance}
      else
        redeemed = min(requested_cents, current_balance)

        Repo.transaction(fn ->
          %{gift_card_id: card.id, delta_cents: -redeemed, entry_type: :redeem}
          |> GiftCardLedgerEntry.changeset()
          |> Repo.insert!()

          %{redeemed_cents: redeemed, remaining_cents: current_balance - redeemed}
        end)
      end
    end
  end

  @doc """
  Deactivates a gift card, preventing future redemptions.
  """
  @spec deactivate(code()) :: {:ok, GiftCard.t()} | {:error, :invalid_code}
  def deactivate(code) when is_binary(code) do
    with {:ok, card} <- lookup_card(code) do
      card |> GiftCard.deactivate_changeset() |> Repo.update()
    end
  end

  @doc """
  Returns the full transaction history for a gift card.
  """
  @spec history(code()) :: {:ok, [GiftCardLedgerEntry.t()]} | {:error, :invalid_code}
  def history(code) when is_binary(code) do
    with {:ok, card} <- lookup_card(code) do
      entries =
        GiftCardLedgerEntry
        |> where([e], e.gift_card_id == ^card.id)
        |> order_by([e], desc: e.inserted_at)
        |> Repo.all()

      {:ok, entries}
    end
  end

  defp find_card(code) do
    with {:ok, card} <- lookup_card(code) do
      if card.active and (is_nil(card.expires_on) or Date.compare(Date.utc_today(), card.expires_on) != :gt) do
        {:ok, card}
      else
        if not card.active or (card.expires_on && Date.compare(Date.utc_today(), card.expires_on) == :gt) do
          {:error, :card_expired}
        else
          {:error, :invalid_code}
        end
      end
    end
  end

  defp lookup_card(code) do
    code_hash = hash(code)

    case Repo.get_by(GiftCard, code_hash: code_hash) do
      nil -> {:error, :invalid_code}
      card -> {:ok, card}
    end
  end

  defp compute_balance(card_id) do
    GiftCardLedgerEntry
    |> where([e], e.gift_card_id == ^card_id)
    |> select([e], sum(e.delta_cents))
    |> Repo.one()
    |> case do
      nil -> 0
      total -> max(total, 0)
    end
  end

  defp generate_code do
    random = :crypto.strong_rand_bytes(@code_bytes) |> Base.encode32(padding: false)
    "#{@code_prefix}-#{random}"
  end

  defp hash(code) do
    :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)
  end
end
```

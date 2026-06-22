```elixir
defmodule Commerce.GiftCardContext do
  @moduledoc """
  Manages gift card issuance, redemption, and balance queries. Gift cards
  carry a monetary value in a specific currency. Partial redemptions are
  allowed and tracked via a balance ledger rather than in-place mutation.
  Each redemption is idempotent via a caller-supplied order reference.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Commerce.{GiftCard, GiftCardRedemption}

  @type card_code :: String.t()
  @type order_ref :: String.t()
  @type amount_cents :: pos_integer()

  @code_length 16
  @code_alphabet ~c(ABCDEFGHJKLMNPQRSTUVWXYZ23456789)

  @doc "Issues a new gift card with `initial_balance_cents` in `currency`."
  @spec issue(amount_cents(), String.t()) ::
          {:ok, GiftCard.t()} | {:error, Ecto.Changeset.t()}
  def issue(initial_balance_cents, currency)
      when is_integer(initial_balance_cents) and initial_balance_cents > 0
      and is_binary(currency) do
    code = generate_code()
    attrs = %{code: code, currency: currency, initial_balance_cents: initial_balance_cents, active: true}
    %GiftCard{} |> GiftCard.changeset(attrs) |> Repo.insert()
  end

  @doc "Returns the current redeemable balance in cents for `card_code`."
  @spec balance(card_code()) :: {:ok, amount_cents()} | {:error, :not_found | :inactive}
  def balance(card_code) when is_binary(card_code) do
    with {:ok, card} <- fetch_active(card_code) do
      redeemed = sum_redeemed(card.id)
      {:ok, card.initial_balance_cents - redeemed}
    end
  end

  @doc """
  Redeems up to `amount_cents` from `card_code` against `order_ref`.
  Returns the actual amount deducted (may be less than requested if
  the balance is insufficient). Idempotent per `order_ref`.
  """
  @spec redeem(card_code(), amount_cents(), order_ref()) ::
          {:ok, %{redeemed_cents: amount_cents(), remaining_cents: non_neg_integer()}}
          | {:error, :not_found | :inactive | :no_balance | :already_redeemed}
  def redeem(card_code, amount_cents, order_ref)
      when is_binary(card_code) and is_integer(amount_cents) and amount_cents > 0
      and is_binary(order_ref) do
    Repo.transaction(fn ->
      with {:ok, card} <- fetch_active(card_code),
           :ok <- check_not_redeemed(card.id, order_ref) do
        redeemed_so_far = sum_redeemed(card.id)
        available = card.initial_balance_cents - redeemed_so_far

        if available == 0 do
          Repo.rollback(:no_balance)
        else
          actual = min(amount_cents, available)
          attrs = %{gift_card_id: card.id, amount_cents: actual, order_ref: order_ref}
          Repo.insert!(%GiftCardRedemption{} |> GiftCardRedemption.changeset(attrs))
          %{redeemed_cents: actual, remaining_cents: available - actual}
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Voids a gift card, preventing further redemptions."
  @spec void(card_code()) :: :ok | {:error, :not_found}
  def void(card_code) when is_binary(card_code) do
    case Repo.get_by(GiftCard, code: card_code) do
      nil -> {:error, :not_found}
      card ->
        card |> GiftCard.changeset(%{active: false}) |> Repo.update!()
        :ok
    end
  end

  defp fetch_active(code) do
    case Repo.get_by(GiftCard, code: code) do
      nil -> {:error, :not_found}
      %GiftCard{active: false} -> {:error, :inactive}
      card -> {:ok, card}
    end
  end

  defp sum_redeemed(card_id) do
    Repo.one(from(r in GiftCardRedemption,
      where: r.gift_card_id == ^card_id,
      select: sum(r.amount_cents)
    )) || 0
  end

  defp check_not_redeemed(card_id, order_ref) do
    if Repo.exists?(from(r in GiftCardRedemption,
         where: r.gift_card_id == ^card_id and r.order_ref == ^order_ref)) do
      {:error, :already_redeemed}
    else
      :ok
    end
  end

  defp generate_code do
    1..@code_length
    |> Enum.map(fn _ -> Enum.random(@code_alphabet) end)
    |> List.to_string()
    |> then(fn code ->
      code
      |> String.graphemes()
      |> Enum.chunk_every(4)
      |> Enum.map(&Enum.join/1)
      |> Enum.join("-")
    end)
  end
end
```

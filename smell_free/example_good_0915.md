```elixir
defmodule Billing.CreditLedger do
  @moduledoc """
  Manages account credits as an append-only ledger. Credits are issued
  for refunds, promotional grants, and loyalty rewards. Debits are applied
  when credits are consumed at checkout. The available balance is always
  derived from the ledger sum rather than stored as a mutable column,
  preventing balance inconsistencies from concurrent writes.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Billing.CreditEntry

  @type account_id :: String.t()
  @type credit_type :: :refund | :promotional | :loyalty | :adjustment
  @type entry_type :: :credit | :debit
  @type amount_cents :: pos_integer()

  @doc "Issues credits to `account_id` for the specified `credit_type` and amount."
  @spec issue(account_id(), amount_cents(), credit_type(), String.t()) ::
          {:ok, CreditEntry.t()} | {:error, Ecto.Changeset.t()}
  def issue(account_id, amount_cents, credit_type, reference)
      when is_binary(account_id) and is_integer(amount_cents) and amount_cents > 0
      and credit_type in [:refund, :promotional, :loyalty, :adjustment] do
    attrs = %{
      account_id: account_id,
      entry_type: "credit",
      credit_type: Atom.to_string(credit_type),
      amount_cents: amount_cents,
      reference: reference
    }
    %CreditEntry{} |> CreditEntry.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Debits up to `amount_cents` from `account_id`'s credit balance against
  `order_id`. Returns `{:error, :insufficient_credits}` when balance is zero.
  """
  @spec apply(account_id(), amount_cents(), String.t()) ::
          {:ok, %{applied_cents: non_neg_integer(), entry: CreditEntry.t()}}
          | {:error, :insufficient_credits | Ecto.Changeset.t()}
  def apply(account_id, amount_cents, order_id)
      when is_binary(account_id) and is_integer(amount_cents) and amount_cents > 0 do
    Repo.transaction(fn ->
      available = balance(account_id)

      if available == 0 do
        Repo.rollback(:insufficient_credits)
      else
        apply_cents = min(amount_cents, available)
        attrs = %{account_id: account_id, entry_type: "debit",
                  credit_type: "checkout", amount_cents: apply_cents, reference: order_id}

        case %CreditEntry{} |> CreditEntry.changeset(attrs) |> Repo.insert() do
          {:ok, entry} -> %{applied_cents: apply_cents, entry: entry}
          {:error, cs} -> Repo.rollback(cs)
        end
      end
    end)
  end

  @doc "Returns the current credit balance in cents for `account_id`."
  @spec balance(account_id()) :: non_neg_integer()
  def balance(account_id) when is_binary(account_id) do
    credits = sum_by_type(account_id, "credit")
    debits = sum_by_type(account_id, "debit")
    max(0, credits - debits)
  end

  @doc "Returns a chronological list of all credit entries for `account_id`."
  @spec history(account_id()) :: [CreditEntry.t()]
  def history(account_id) when is_binary(account_id) do
    from(e in CreditEntry,
      where: e.account_id == ^account_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  defp sum_by_type(account_id, entry_type) do
    from(e in CreditEntry,
      where: e.account_id == ^account_id and e.entry_type == ^entry_type,
      select: sum(e.amount_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end
end
```

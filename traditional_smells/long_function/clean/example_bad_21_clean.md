```elixir
defmodule Payments.PayoutDisbursement do
  @moduledoc """
  Handles disbursement of earned funds to seller bank accounts,
  reconciling the earnings ledger and notifying sellers on completion.
  """

  alias Payments.{Payout, EarningsLedger, BankAccount, Repo}
  alias Sellers.Seller
  alias Integrations.{StripeConnect, Mailer}
  require Logger

  @minimum_payout_cents 5_000
  @payout_fee_cents 25
  @supported_currencies ~w(usd eur gbp)

  def disburse(seller_id, currency) when currency in @supported_currencies do
    Logger.info("Initiating payout for seller=#{seller_id} currency=#{currency}")

    # --- Load and validate seller ---
    case Repo.get(Seller, seller_id) do
      nil ->
        {:error, :seller_not_found}

      %Seller{status: status} when status not in [:active, :verified] ->
        Logger.warning("Payout blocked for seller #{seller_id} with status #{status}")
        {:error, {:seller_not_eligible, status}}

      %Seller{} = seller ->
        # --- Aggregate pending earnings ---
        pending_entries =
          EarningsLedger
          |> EarningsLedger.for_seller(seller_id)
          |> EarningsLedger.in_currency(currency)
          |> EarningsLedger.pending()
          |> Repo.all()

        gross_amount_cents =
          Enum.reduce(pending_entries, 0, fn e, acc -> acc + e.amount_cents end)

        net_amount_cents = gross_amount_cents - @payout_fee_cents

        if gross_amount_cents < @minimum_payout_cents do
          Logger.info("Seller #{seller_id} below minimum payout: #{gross_amount_cents} cents")
          {:error, {:below_minimum_payout, gross_amount_cents, @minimum_payout_cents}}
        else
          # --- Verify bank account ---
          case Repo.get_by(BankAccount, seller_id: seller_id, currency: currency, status: :verified) do
            nil ->
              {:error, :no_verified_bank_account}

            %BankAccount{} = bank_account ->
              # --- Initiate gateway transfer ---
              transfer_payload = %{
                destination: bank_account.gateway_account_id,
                amount: net_amount_cents,
                currency: currency,
                description: "Seller payout – #{seller_id}",
                metadata: %{
                  seller_id: seller_id,
                  entry_count: length(pending_entries)
                }
              }

              case StripeConnect.create_transfer(transfer_payload) do
                {:ok, %{transfer_id: transfer_id, arrival_date: arrival_date}} ->
                  # --- Create payout record ---
                  {:ok, payout} =
                    Repo.insert(Payout.changeset(%Payout{}, %{
                      seller_id: seller_id,
                      bank_account_id: bank_account.id,
                      gateway_transfer_id: transfer_id,
                      gross_amount_cents: gross_amount_cents,
                      fee_cents: @payout_fee_cents,
                      net_amount_cents: net_amount_cents,
                      currency: currency,
                      status: :in_transit,
                      estimated_arrival: arrival_date,
                      initiated_at: DateTime.utc_now()
                    }))

                  # --- Mark ledger entries as paid ---
                  Enum.each(pending_entries, fn entry ->
                    entry
                    |> EarningsLedger.changeset(%{
                      status: :paid,
                      payout_id: payout.id,
                      settled_at: DateTime.utc_now()
                    })
                    |> Repo.update!()
                  end)

                  # --- Notify seller ---
                  Mailer.send_payout_notification(%{
                    to: seller.email,
                    seller_name: seller.display_name,
                    amount: net_amount_cents / 100,
                    currency: String.upcase(currency),
                    estimated_arrival: arrival_date,
                    payout_id: payout.id
                  })

                  Logger.info("Payout #{payout.id} initiated for seller #{seller_id}: #{net_amount_cents} #{currency}")
                  {:ok, payout}

                {:error, %{code: code, message: msg}} ->
                  Logger.error("Transfer failed for seller #{seller_id}: #{code} – #{msg}")
                  {:error, {:transfer_failed, code}}
              end
          end
        end
    end
  end

  def cancel_payout(payout_id) do
    case Repo.get(Payout, payout_id) do
      nil -> {:error, :not_found}
      %Payout{status: :in_transit} = p ->
        p |> Payout.changeset(%{status: :cancelled}) |> Repo.update()
      _ ->
        {:error, :cannot_cancel}
    end
  end
end
```

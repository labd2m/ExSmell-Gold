```elixir
defmodule MyApp.Payments.ReconciliationJob do
  @moduledoc """
  An Oban worker that reconciles the local payment records against the
  Stripe API to detect discrepancies — charges recorded locally but
  absent from Stripe, or Stripe charges with no matching local record.
  Discrepancies are written to the `payment_discrepancies` table for
  operator review rather than being auto-corrected.

  Runs nightly. Looks back a configurable number of hours to cover the
  previous reconciliation window with a small overlap.
  """

  use Oban.Worker, queue: :reconciliation, max_attempts: 2

  require Logger

  alias MyApp.Repo
  alias MyApp.Billing.{Payment, PaymentDiscrepancy}
  alias MyApp.Integrations.StripeClient

  import Ecto.Query, warn: false

  @lookback_hours 26

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    window_start = DateTime.add(DateTime.utc_now(), -@lookback_hours, :hour)

    Logger.info("reconciliation_job_started", window_start: window_start)

    with {:ok, local_payments} <- fetch_local_payments(window_start),
         {:ok, stripe_charges} <- fetch_stripe_charges(window_start) do
      discrepancies = detect_discrepancies(local_payments, stripe_charges)
      persist_discrepancies(discrepancies)

      Logger.info("reconciliation_job_finished",
        local_count: length(local_payments),
        stripe_count: length(stripe_charges),
        discrepancy_count: length(discrepancies)
      )

      :ok
    end
  end

  @spec fetch_local_payments(DateTime.t()) :: {:ok, [Payment.t()]} | {:error, term()}
  defp fetch_local_payments(since) do
    payments =
      Payment
      |> where([p], p.inserted_at >= ^since and p.status in [:captured, :refunded])
      |> select([p], %{id: p.id, provider_id: p.stripe_charge_id, amount_cents: p.amount_cents,
                       status: p.status, inserted_at: p.inserted_at})
      |> Repo.all()

    {:ok, payments}
  end

  @spec fetch_stripe_charges(DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  defp fetch_stripe_charges(since) do
    StripeClient.list_charges(created_after: DateTime.to_unix(since))
  end

  @spec detect_discrepancies([map()], [map()]) :: [map()]
  defp detect_discrepancies(local_payments, stripe_charges) do
    local_by_provider_id = Map.new(local_payments, &{&1.provider_id, &1})
    stripe_by_id = Map.new(stripe_charges, &{&1["id"], &1})

    missing_from_stripe =
      local_payments
      |> Enum.reject(fn p -> Map.has_key?(stripe_by_id, p.provider_id) end)
      |> Enum.map(fn p ->
        %{type: :missing_from_stripe, local_id: p.id, provider_id: p.provider_id,
          amount_cents: p.amount_cents}
      end)

    missing_locally =
      stripe_charges
      |> Enum.reject(fn c -> Map.has_key?(local_by_provider_id, c["id"]) end)
      |> Enum.map(fn c ->
        %{type: :missing_locally, local_id: nil, provider_id: c["id"],
          amount_cents: c["amount"]}
      end)

    amount_mismatches =
      local_payments
      |> Enum.flat_map(fn p ->
        case Map.get(stripe_by_id, p.provider_id) do
          nil -> []
          charge when charge["amount"] != p.amount_cents ->
            [%{type: :amount_mismatch, local_id: p.id, provider_id: p.provider_id,
               local_amount: p.amount_cents, stripe_amount: charge["amount"]}]
          _ -> []
        end
      end)

    missing_from_stripe ++ missing_locally ++ amount_mismatches
  end

  @spec persist_discrepancies([map()]) :: :ok
  defp persist_discrepancies([]), do: :ok

  defp persist_discrepancies(discrepancies) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    records =
      Enum.map(discrepancies, fn d ->
        Map.merge(d, %{detected_at: now, status: :unreviewed})
      end)

    Repo.insert_all(PaymentDiscrepancy, records, on_conflict: :nothing)
    :ok
  end
end
```

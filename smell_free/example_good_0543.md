# File: `example_good_543.md`

```elixir
defmodule Billing.SubscriptionInvoicer do
  @moduledoc """
  Generates invoices from subscription billing cycles, applying
  proration for mid-cycle plan changes and metered usage charges.

  Invoice creation is transactional: all line items are inserted with
  the invoice in a single database operation to prevent partial records.
  """

  import Ecto.Query, warn: false

  alias Billing.{Invoice, InvoiceLine, Repo, UsageRecord}
  alias Subscriptions.{Plan, Subscription}

  @type invoice_opts :: [
          billing_date: Date.t(),
          include_usage: boolean()
        ]

  @type invoicing_result ::
          {:ok, Invoice.t()}
          | {:error, :subscription_not_active}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Generates a billing invoice for a subscription covering the period
  ending on `billing_date`.

  When `:include_usage` is `true` (default), any unbilled metered usage
  for the period is appended as additional line items.

  Returns `{:ok, invoice}` or `{:error, reason}`.
  """
  @spec generate(Subscription.t(), invoice_opts()) :: invoicing_result()
  def generate(%Subscription{status: :active} = sub, opts \\ []) do
    billing_date = Keyword.get(opts, :billing_date, Date.utc_today())
    include_usage = Keyword.get(opts, :include_usage, true)

    Repo.transaction(fn ->
      plan = Repo.get!(Plan, sub.plan_id)
      base_lines = build_base_lines(sub, plan)
      usage_lines = if include_usage, do: fetch_usage_lines(sub, billing_date), else: []
      all_lines = base_lines ++ usage_lines

      total_cents = Enum.sum(Enum.map(all_lines, & &1.amount_cents))

      invoice_attrs = %{
        customer_id: sub.customer_id,
        subscription_id: sub.id,
        currency: plan.currency,
        period_start: sub.current_period_start,
        period_end: sub.current_period_end,
        billing_date: billing_date,
        total_cents: total_cents,
        status: :open
      }

      invoice =
        invoice_attrs
        |> Invoice.changeset()
        |> Repo.insert!()

      Enum.each(all_lines, fn line_attrs ->
        line_attrs
        |> Map.put(:invoice_id, invoice.id)
        |> InvoiceLine.changeset()
        |> Repo.insert!()
      end)

      mark_usage_billed(sub, billing_date)

      Repo.preload(invoice, :lines)
    end)
  end

  def generate(%Subscription{}, _opts), do: {:error, :subscription_not_active}

  @doc """
  Returns the total unbilled usage amount in cents for a subscription
  up to and including `as_of` date.
  """
  @spec unbilled_usage_cents(Subscription.t(), Date.t()) :: non_neg_integer()
  def unbilled_usage_cents(%Subscription{id: sub_id}, as_of) do
    UsageRecord
    |> where([u], u.subscription_id == ^sub_id and u.billed == false and u.recorded_on <= ^as_of)
    |> select([u], sum(u.amount_cents))
    |> Repo.one()
    |> case do
      nil -> 0
      total -> total
    end
  end

  defp build_base_lines(%Subscription{} = sub, %Plan{} = plan) do
    [
      %{
        description: "#{plan.name} – #{format_period(sub.current_period_start, sub.current_period_end)}",
        quantity: 1,
        unit_amount_cents: plan.amount_cents,
        amount_cents: plan.amount_cents,
        line_type: :subscription
      }
    ]
  end

  defp fetch_usage_lines(%Subscription{id: sub_id, customer_id: cid}, billing_date) do
    UsageRecord
    |> where([u], u.subscription_id == ^sub_id and u.billed == false and u.recorded_on <= ^billing_date)
    |> group_by([u], u.metric)
    |> select([u], %{metric: u.metric, total_cents: sum(u.amount_cents)})
    |> Repo.all()
    |> Enum.map(fn %{metric: metric, total_cents: cents} ->
      %{
        description: "Usage: #{metric}",
        quantity: 1,
        unit_amount_cents: cents,
        amount_cents: cents,
        line_type: :usage
      }
    end)
  end

  defp mark_usage_billed(%Subscription{id: sub_id}, billing_date) do
    UsageRecord
    |> where([u], u.subscription_id == ^sub_id and u.billed == false and u.recorded_on <= ^billing_date)
    |> Repo.update_all(set: [billed: true, billed_on: billing_date])
  end

  defp format_period(%Date{} = from, %Date{} = to) do
    "#{Date.to_iso8601(from)} – #{Date.to_iso8601(to)}"
  end
end
```

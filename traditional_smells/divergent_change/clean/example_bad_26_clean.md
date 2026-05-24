```elixir
defmodule MyApp.PaymentService do
  @moduledoc """
  Provides operations for charging customers, processing refunds,
  generating financial reports, and managing payment disputes.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Payment, Refund, Dispute}
  alias MyApp.Gateway.Stripe
  import Ecto.Query



  @doc """
  Charges the customer's saved card on file for the given amount (in cents).
  """
  def charge_card(customer_id, amount_cents, description) when amount_cents > 0 do
    with {:ok, stripe_customer} <- Stripe.get_customer(customer_id),
         {:ok, charge} <- Stripe.create_charge(%{
           customer: stripe_customer.id,
           amount: amount_cents,
           currency: "usd",
           description: description
         }) do
      payment =
        %Payment{}
        |> Payment.changeset(%{
          customer_id: customer_id,
          stripe_charge_id: charge.id,
          amount_cents: amount_cents,
          status: :captured,
          description: description,
          charged_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, payment}
    end
  end


  @doc """
  Processes a full or partial refund for a given payment.
  """
  def process_refund(%Payment{} = payment, refund_cents) do
    max_refundable = payment.amount_cents - already_refunded(payment.id)

    if refund_cents > max_refundable do
      {:error, :exceeds_refundable_amount}
    else
      with {:ok, stripe_refund} <- Stripe.create_refund(%{
             charge: payment.stripe_charge_id,
             amount: refund_cents
           }) do
        refund =
          %Refund{}
          |> Refund.changeset(%{
            payment_id: payment.id,
            stripe_refund_id: stripe_refund.id,
            amount_cents: refund_cents,
            issued_at: DateTime.utc_now()
          })
          |> Repo.insert!()

        {:ok, refund}
      end
    end
  end

  defp already_refunded(payment_id) do
    Repo.one(from r in Refund, where: r.payment_id == ^payment_id, select: sum(r.amount_cents)) || 0
  end


  @doc """
  Generates a monthly revenue report for the given year and month.
  Returns aggregated totals grouped by day.
  """
  def generate_monthly_report(year, month) do
    start_date = Date.new!(year, month, 1)
    end_date = Date.end_of_month(start_date)

    rows =
      from(p in Payment,
        where: fragment("DATE(?)", p.charged_at) >= ^start_date,
        where: fragment("DATE(?)", p.charged_at) <= ^end_date,
        where: p.status == :captured,
        group_by: fragment("DATE(?)", p.charged_at),
        select: %{
          date: fragment("DATE(?)", p.charged_at),
          total_cents: sum(p.amount_cents),
          count: count(p.id)
        }
      )
      |> Repo.all()

    total = Enum.sum(Enum.map(rows, & &1.total_cents))
    %{period: "#{year}-#{String.pad_leading("#{month}", 2, "0")}", rows: rows, total_cents: total}
  end

  @doc """
  Exports a pre-built report map to CSV format as a binary string.
  """
  def export_report_csv(%{rows: rows}) do
    header = "date,total_cents,count\n"

    body =
      Enum.map_join(rows, "\n", fn %{date: d, total_cents: t, count: c} ->
        "#{d},#{t},#{c}"
      end)

    header <> body
  end


  @doc """
  Records an incoming chargeback dispute from Stripe webhook data.
  """
  def record_dispute(%Payment{} = payment, stripe_dispute_data) do
    %Dispute{}
    |> Dispute.changeset(%{
      payment_id: payment.id,
      stripe_dispute_id: stripe_dispute_data["id"],
      reason: stripe_dispute_data["reason"],
      amount_cents: stripe_dispute_data["amount"],
      status: :open,
      evidence_due_by: parse_due_date(stripe_dispute_data["evidence_details"]["due_by"])
    })
    |> Repo.insert()
  end

  defp parse_due_date(unix_ts) when is_integer(unix_ts) do
    DateTime.from_unix!(unix_ts)
  end
  defp parse_due_date(_), do: nil

end
```

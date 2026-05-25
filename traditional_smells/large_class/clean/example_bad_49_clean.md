```elixir
defmodule TaxEngine do
  @moduledoc """
  Comprehensive tax subsystem: rate lookup, order tax calculation, exemption
  handling, VAT validation, jurisdiction management, tax invoice generation,
  return filing, liability reconciliation, and export utilities.
  """

  require Logger
  import Ecto.Query
  alias Tax.Repo
  alias Tax.TaxRate
  alias Tax.TaxJurisdiction
  alias Tax.TaxExemption
  alias Tax.TaxInvoice
  alias Tax.TaxReturn
  alias Tax.TaxLiability

  @vat_validation_api "https://api.vatcheck.example.com/validate"
  @default_rate Decimal.new("0.00")


  def lookup_tax_rate(country_code, product_category) do
    case Repo.get_by(TaxRate,
           country_code: country_code,
           product_category: product_category,
           active: true
         ) do
      nil ->
        fallback = Repo.get_by(TaxRate, country_code: country_code, product_category: "default", active: true)
        %{rate: (fallback && fallback.rate) || @default_rate, source: :fallback}

      rate ->
        %{rate: rate.rate, source: :exact}
    end
  end


  def calculate_order_tax(order, user) do
    jurisdiction = Repo.get_by(TaxJurisdiction, country_code: user.country_code)

    if is_nil(jurisdiction) do
      %{tax_amount: Decimal.new("0"), rate: @default_rate, exempt: false}
    else
      case apply_tax_exemption(user, jurisdiction) do
        {:exempt, reason} ->
          Logger.info("Order #{order.id} exempt from tax: #{reason}")
          %{tax_amount: Decimal.new("0"), rate: @default_rate, exempt: true, reason: reason}

        :taxable ->
          %{rate: rate} = lookup_tax_rate(user.country_code, order.product_category || "default")
          tax_amount = Decimal.mult(order.subtotal, rate) |> Decimal.round(2)
          %{tax_amount: tax_amount, rate: rate, exempt: false}
      end
    end
  end


  def apply_tax_exemption(user, jurisdiction) do
    exemption = Repo.get_by(TaxExemption, user_id: user.id, jurisdiction_id: jurisdiction.id, active: true)

    cond do
      exemption && DateTime.compare(exemption.expires_at, DateTime.utc_now()) == :gt ->
        {:exempt, exemption.reason}

      jurisdiction.b2b_exempt and user.is_business and validate_vat_number(user.vat_number) == :valid ->
        {:exempt, "valid B2B VAT number"}

      true ->
        :taxable
    end
  end


  def validate_vat_number(nil), do: :invalid
  def validate_vat_number(""), do: :invalid

  def validate_vat_number(vat_number) do
    case HTTPoison.get("#{@vat_validation_api}?vat=#{URI.encode(vat_number)}") do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"valid" => true}} -> :valid
          _ -> :invalid
        end

      _ ->
        Logger.warning("VAT validation API unreachable for #{vat_number}, defaulting to invalid")
        :invalid
    end
  end


  def register_tax_jurisdiction(attrs) do
    changeset =
      TaxJurisdiction.changeset(%TaxJurisdiction{}, %{
        country_code: attrs[:country_code],
        name: attrs[:name],
        b2b_exempt: attrs[:b2b_exempt] || false,
        digital_services_rate: attrs[:digital_services_rate] || @default_rate
      })

    case Repo.insert(changeset, on_conflict: :replace_all, conflict_target: :country_code) do
      {:ok, j} ->
        Logger.info("Jurisdiction #{j.country_code} registered")
        {:ok, j}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def generate_tax_invoice(order, tax_details) do
    attrs = %{
      order_id: order.id,
      invoice_number: "TAX-#{:erlang.unique_integer([:positive])}",
      subtotal: order.subtotal,
      tax_rate: tax_details.rate,
      tax_amount: tax_details.tax_amount,
      total: Decimal.add(order.subtotal, tax_details.tax_amount),
      issued_at: DateTime.utc_now()
    }

    case Repo.insert(TaxInvoice.changeset(%TaxInvoice{}, attrs)) do
      {:ok, inv} ->
        Logger.info("Tax invoice #{inv.invoice_number} issued for order #{order.id}")
        {:ok, inv}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def file_tax_return(jurisdiction_id, period) do
    invoices =
      from(ti in TaxInvoice,
        join: o in assoc(ti, :order),
        where:
          o.user_country == ^period.country_code and
            ti.issued_at >= ^period.from and
            ti.issued_at <= ^period.to
      )
      |> Repo.all()

    total_tax = Enum.reduce(invoices, Decimal.new("0"), &Decimal.add(&2, &1.tax_amount))

    attrs = %{
      jurisdiction_id: jurisdiction_id,
      period_from: period.from,
      period_to: period.to,
      total_tax_collected: total_tax,
      invoice_count: length(invoices),
      status: :submitted,
      filed_at: DateTime.utc_now()
    }

    case Repo.insert(TaxReturn.changeset(%TaxReturn{}, attrs)) do
      {:ok, ret} ->
        Logger.info("Tax return filed for jurisdiction #{jurisdiction_id}, total tax: #{total_tax}")
        {:ok, ret}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def reconcile_tax_liabilities(period) do
    liabilities =
      from(tl in TaxLiability,
        where: tl.period_from >= ^period.from and tl.period_to <= ^period.to and tl.status == :outstanding
      )
      |> Repo.all()

    returns =
      from(tr in TaxReturn,
        where: tr.period_from >= ^period.from and tr.period_to <= ^period.to
      )
      |> Repo.all()

    filed_total   = Enum.reduce(returns,     Decimal.new("0"), &Decimal.add(&2, &1.total_tax_collected))
    owed_total    = Enum.reduce(liabilities, Decimal.new("0"), &Decimal.add(&2, &1.amount))
    discrepancy   = Decimal.sub(owed_total, filed_total)

    %{filed: filed_total, owed: owed_total, discrepancy: discrepancy}
  end


  def export_tax_summary(from_date, to_date) do
    invoices =
      from(ti in TaxInvoice,
        where: ti.issued_at >= ^from_date and ti.issued_at <= ^to_date,
        order_by: [asc: ti.issued_at]
      )
      |> Repo.all()

    header = "invoice_number,order_id,subtotal,tax_rate,tax_amount,total,issued_at\n"

    rows =
      Enum.map(invoices, fn inv ->
        "#{inv.invoice_number},#{inv.order_id},#{inv.subtotal},#{inv.tax_rate},#{inv.tax_amount},#{inv.total},#{inv.issued_at}\n"
      end)

    [header | rows] |> Enum.join()
  end
end
```

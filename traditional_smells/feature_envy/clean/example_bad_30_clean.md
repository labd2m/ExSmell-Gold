```elixir
defmodule Subscriptions.SubscriptionContract do
  @moduledoc "Represents an active subscription contract."

  defstruct [
    :id,
    :customer_id,
    :plan_code,
    :billing_cycle,
    :base_price,
    :currency,
    :seats,
    :renewal_discount_pct,
    :started_at,
    :current_period_end,
    :auto_renew,
    :status
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      customer_id: "CUST-1102",
      plan_code: "PRO_ANNUAL",
      billing_cycle: :annual,
      base_price: Decimal.new("3600.00"),
      currency: "USD",
      seats: 10,
      renewal_discount_pct: Decimal.new("0.10"),
      started_at: ~D[2023-04-01],
      current_period_end: ~D[2024-04-01],
      auto_renew: true,
      status: :active
    }
  end

  def renewal_amount(%__MODULE__{base_price: price, seats: seats}) do
    Decimal.mult(price, Decimal.new(seats))
  end

  def next_billing_date(%__MODULE__{current_period_end: end_date, billing_cycle: :annual}) do
    Date.add(end_date, 365)
  end
  def next_billing_date(%__MODULE__{current_period_end: end_date}) do
    Date.add(end_date, 30)
  end

  def is_annual?(%__MODULE__{billing_cycle: :annual}), do: true
  def is_annual?(_), do: false

  def discount_for_renewal(%__MODULE__{renewal_discount_pct: d}), do: d

  def auto_renew?(%__MODULE__{auto_renew: true}), do: true
  def auto_renew?(_), do: false

  def plan_display(%__MODULE__{plan_code: code, seats: seats}) do
    "#{code} (#{seats} seats)"
  end
end

defmodule Subscriptions.RenewalInvoice do
  @moduledoc "A generated renewal invoice for a subscription contract."

  defstruct [:contract_id, :customer_id, :line_items, :total, :currency, :due_date, :created_at]
end

defmodule Subscriptions.BillingCycle do
  @moduledoc """
  Manages subscription billing cycles, renewal invoicing, and
  auto-renewal scheduling for all active contracts.
  """

  alias Subscriptions.{SubscriptionContract, RenewalInvoice}
  require Logger

  @doc """
  Processes renewal invoices for a list of contract IDs that are
  due for renewal within the next `look_ahead_days` days.
  """
  def process_renewals(contract_ids, look_ahead_days \\ 30) do
    contract_ids
    |> Enum.filter(fn id ->
      contract = SubscriptionContract.get!(id)
      SubscriptionContract.auto_renew?(contract) and
        Date.diff(contract.current_period_end, Date.utc_today()) <= look_ahead_days
    end)
    |> Enum.map(&generate_renewal_invoice/1)
    |> tap(fn invoices ->
      Logger.info("Generated #{length(invoices)} renewal invoice(s).")
    end)
  end

  defp generate_renewal_invoice(contract_id) do
    contract     = SubscriptionContract.get!(contract_id)
    base_amount  = SubscriptionContract.renewal_amount(contract)
    due_date     = SubscriptionContract.next_billing_date(contract)
    annual       = SubscriptionContract.is_annual?(contract)
    discount_pct = SubscriptionContract.discount_for_renewal(contract)

    discount_amount = Decimal.mult(base_amount, discount_pct)
    total           = Decimal.round(Decimal.sub(base_amount, discount_amount), 2)

    line_items = [
      %{description: SubscriptionContract.plan_display(contract), amount: base_amount},
      %{description: "Renewal discount #{Decimal.mult(discount_pct, Decimal.new("100"))}%", amount: Decimal.negate(discount_amount)}
    ]

    Logger.info("Renewal invoice created for contract #{contract_id}: #{total} #{contract.currency}, annual=#{annual}")

    %RenewalInvoice{
      contract_id: contract_id,
      customer_id: contract.customer_id,
      line_items:  line_items,
      total:       total,
      currency:    contract.currency,
      due_date:    due_date,
      created_at:  DateTime.utc_now()
    }
  end
end
```

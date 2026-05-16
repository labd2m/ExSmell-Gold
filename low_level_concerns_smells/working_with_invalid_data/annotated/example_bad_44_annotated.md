# Example 44: Energy Utility Meter Reading Processor - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `Utility.MeterProcessor.calculate_consumption_bill/4` function
- **Affected Functions**: `calculate_consumption_bill/4`
- **Explanation**: The function does not validate that `current_reading` and `previous_reading` are numbers before passing them to the subtraction operator. Strings or atoms coming from an upstream parser will produce a confusing ArithmeticError inside the function body instead of a clear boundary error.

## Code

```elixir
defmodule Utility.MeterProcessor do
  @moduledoc """
  Processes smart meter readings, calculates consumption, applies tiered
  pricing, and generates utility bills for residential and commercial accounts.
  """

  alias Utility.{Account, MeterReading, Bill, TariffSchedule, PaymentPlan, Notification}

  @residential_tiers [
    {0, 300, 0.085},
    {300, 700, 0.112},
    {700, :infinity, 0.148}
  ]

  @commercial_base_charge 22.50

  def ingest_meter_reading(account_id, meter_id, raw_reading, read_at) do
    with {:ok, account} <- Account.get(account_id),
         {:ok, meter} <- Account.get_meter(account_id, meter_id),
         :ok <- validate_reading_sequence(meter_id, raw_reading, read_at) do

      reading = %MeterReading{
        id: generate_reading_id(),
        account_id: account_id,
        meter_id: meter_id,
        raw_value: raw_reading,
        unit: meter.unit,
        read_at: read_at,
        source: :smart_meter,
        ingested_at: DateTime.utc_now()
      }

      {:ok, _} = MeterReading.insert(reading)
      {:ok, reading}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `current_reading` and `previous_reading`
  # VALIDATION: are not validated to be numeric values before they are used in
  # VALIDATION: the subtraction expression on the very first line of computation.
  # VALIDATION: If an upstream parser passes them as strings (e.g., "04821"),
  # VALIDATION: the ArithmeticError will surface inside this function's body
  # VALIDATION: with no indication that the caller supplied non-numeric data.
  def calculate_consumption_bill(account_id, billing_period, current_reading, previous_reading) do
    with {:ok, account} <- Account.get(account_id),
         {:ok, tariff} <- TariffSchedule.get_for_account(account_id, billing_period.start_date),
         :ok <- validate_billing_period(billing_period) do

      # No type validation before arithmetic on meter readings
      consumption = current_reading - previous_reading

      if consumption < 0 do
        {:error, :negative_consumption_detected}
      else
        charges = compute_charges(consumption, account.account_type, tariff)
        taxes = charges.subtotal * tariff.tax_rate
        total = charges.subtotal + taxes

        bill = %Bill{
          id: generate_bill_id(),
          account_id: account_id,
          billing_period_start: billing_period.start_date,
          billing_period_end: billing_period.end_date,
          previous_reading: previous_reading,
          current_reading: current_reading,
          consumption: consumption,
          consumption_unit: "kWh",
          energy_charges: charges.energy,
          demand_charges: charges.demand,
          fixed_charges: charges.fixed,
          subtotal: Float.round(charges.subtotal, 2),
          tax_rate: tariff.tax_rate,
          taxes: Float.round(taxes, 2),
          total_due: Float.round(total, 2),
          due_date: Date.add(billing_period.end_date, 21),
          status: :issued,
          issued_at: DateTime.utc_now()
        }

        {:ok, _} = Bill.insert(bill)
        {:ok, _} = Notification.send(account.customer_id, :bill_ready, bill)

        {:ok, bill}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def apply_payment(bill_id, payment_amount, payment_method) do
    with {:ok, bill} <- Bill.get(bill_id),
         :ok <- validate_bill_payable(bill) do

      remaining = bill.total_due - payment_amount

      status =
        cond do
          remaining <= 0 -> :paid
          remaining < bill.total_due -> :partially_paid
          true -> :unpaid
        end

      {:ok, _} = Bill.update(bill_id, %{
        amount_paid: (bill.amount_paid || 0) + payment_amount,
        remaining_balance: max(0, remaining),
        status: status,
        last_payment_at: DateTime.utc_now()
      })

      if remaining < 0 do
        credit = abs(remaining)
        {:ok, _} = Account.apply_credit(bill.account_id, credit)
      end

      {:ok, %{bill_id: bill_id, payment_amount: payment_amount, status: status, remaining: max(0, remaining)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def enroll_in_payment_plan(account_id, bill_id, num_installments) do
    with {:ok, account} <- Account.get(account_id),
         {:ok, bill} <- Bill.get(bill_id),
         :ok <- validate_bill_eligible_for_plan(bill),
         :ok <- validate_installment_count(num_installments) do

      installment_amount = Float.round(bill.total_due / num_installments, 2)
      first_due = Date.utc_today() |> Date.add(14)

      installments =
        Enum.map(1..num_installments, fn i ->
          %{
            number: i,
            amount: installment_amount,
            due_date: Date.add(first_due, (i - 1) * 30),
            status: :pending
          }
        end)

      plan = %PaymentPlan{
        id: generate_plan_id(),
        account_id: account_id,
        bill_id: bill_id,
        total_amount: bill.total_due,
        num_installments: num_installments,
        installment_amount: installment_amount,
        installments: installments,
        status: :active,
        created_at: DateTime.utc_now()
      }

      {:ok, _} = PaymentPlan.insert(plan)
      {:ok, _} = Bill.update(bill_id, %{payment_plan_id: plan.id, status: :on_payment_plan})

      {:ok, plan}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def generate_usage_report(account_id, start_date, end_date) do
    with {:ok, account} <- Account.get(account_id),
         {:ok, readings} <- MeterReading.list_for_range(account_id, start_date, end_date),
         {:ok, bills} <- Bill.list_for_range(account_id, start_date, end_date) do

      total_consumption = Enum.sum(Enum.map(bills, & &1.consumption))
      total_billed = Enum.sum(Enum.map(bills, & &1.total_due))
      avg_monthly = if length(bills) > 0, do: total_billed / length(bills), else: 0

      report = %{
        account_id: account_id,
        period: %{start: start_date, end: end_date},
        reading_count: length(readings),
        bill_count: length(bills),
        total_consumption_kwh: total_consumption,
        total_billed: Float.round(total_billed, 2),
        avg_monthly_bill: Float.round(avg_monthly, 2),
        generated_at: DateTime.utc_now()
      }

      {:ok, report}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp compute_charges(consumption, :residential, tariff) do
    energy_charge = apply_tiered_pricing(consumption, @residential_tiers)
    fixed_charge = tariff.residential_fixed_charge

    %{energy: Float.round(energy_charge, 2), demand: 0.0, fixed: fixed_charge,
      subtotal: energy_charge + fixed_charge}
  end

  defp compute_charges(consumption, :commercial, tariff) do
    energy_charge = consumption * tariff.commercial_energy_rate
    demand_charge = @commercial_base_charge
    fixed_charge = tariff.commercial_fixed_charge

    %{energy: Float.round(energy_charge, 2), demand: demand_charge, fixed: fixed_charge,
      subtotal: energy_charge + demand_charge + fixed_charge}
  end

  defp apply_tiered_pricing(consumption, tiers) do
    Enum.reduce(tiers, {consumption, 0.0}, fn {from, to, rate}, {remaining, total} ->
      tier_max = if to == :infinity, do: remaining, else: min(remaining, to - from)
      used = min(remaining, tier_max)
      {remaining - used, total + used * rate}
    end)
    |> elem(1)
  end

  defp validate_reading_sequence(meter_id, reading, read_at) do
    case MeterReading.last_for_meter(meter_id) do
      {:ok, nil} -> :ok
      {:ok, last} ->
        cond do
          reading < last.raw_value -> {:error, :reading_less_than_previous}
          DateTime.before?(read_at, last.read_at) -> {:error, :reading_timestamp_in_past}
          true -> :ok
        end
      _ -> :ok
    end
  end

  defp validate_billing_period(%{start_date: s, end_date: e}) do
    if Date.compare(s, e) == :lt, do: :ok, else: {:error, :invalid_billing_period}
  end

  defp validate_bill_payable(%{status: :issued}), do: :ok
  defp validate_bill_payable(%{status: :partially_paid}), do: :ok
  defp validate_bill_payable(%{status: :on_payment_plan}), do: :ok
  defp validate_bill_payable(_), do: {:error, :bill_not_payable}

  defp validate_bill_eligible_for_plan(%{status: :issued}), do: :ok
  defp validate_bill_eligible_for_plan(_), do: {:error, :bill_not_eligible_for_payment_plan}

  defp validate_installment_count(n) when n in [2, 3, 4, 6, 12], do: :ok
  defp validate_installment_count(_), do: {:error, :invalid_installment_count}

  defp generate_reading_id, do: "rdg_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  defp generate_bill_id, do: "bill_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  defp generate_plan_id, do: "plan_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
end
```

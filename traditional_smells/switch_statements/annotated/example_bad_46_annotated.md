# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `ContractManager.notice_period_days/1` and `ContractManager.renewal_term_months/1`
- **Affected functions:** `notice_period_days/1`, `renewal_term_months/1`
- **Short explanation:** The same `case` branching over contract type (`:monthly`, `:quarterly`, `:annual`, `:biennial`) is duplicated in `notice_period_days/1` and `renewal_term_months/1`. Introducing a new contract type forces changes in both functions.

---

```elixir
defmodule ContractManager do
  @moduledoc """
  Manages customer contract lifecycles in a B2B SaaS platform,
  including renewal scheduling, notice period enforcement, and
  termination eligibility calculations.
  """

  alias ContractManager.{Contract, Customer, RenewalRecord, NotificationService}

  @type contract_type :: :monthly | :quarterly | :annual | :biennial

  @spec schedule_renewal(Contract.t()) :: {:ok, RenewalRecord.t()} | {:error, String.t()}
  def schedule_renewal(%Contract{} = contract) do
    term_months = renewal_term_months(contract.type)
    renewal_date = shift_months(contract.end_date, term_months)
    notice_by = Date.add(contract.end_date, -notice_period_days(contract.type))

    if Date.compare(Date.utc_today(), notice_by) == :gt do
      {:error, "notice period has already passed for contract #{contract.id}"}
    else
      record = %RenewalRecord{
        contract_id: contract.id,
        renewal_date: renewal_date,
        term_months: term_months,
        notice_deadline: notice_by,
        status: :scheduled
      }

      {:ok, record}
    end
  end

  @spec termination_eligible?(Contract.t()) :: boolean()
  def termination_eligible?(%Contract{} = contract) do
    cutoff = Date.add(contract.end_date, -notice_period_days(contract.type))
    Date.compare(Date.utc_today(), cutoff) != :gt
  end

  @spec contract_summary(Contract.t()) :: map()
  def contract_summary(%Contract{} = contract) do
    %{
      id: contract.id,
      type: contract.type,
      start_date: contract.start_date,
      end_date: contract.end_date,
      notice_period_days: notice_period_days(contract.type),
      renewal_term_months: renewal_term_months(contract.type),
      termination_eligible: termination_eligible?(contract),
      auto_renews: contract.auto_renew
    }
  end

  @spec send_renewal_reminders([Contract.t()]) :: %{sent: integer(), skipped: integer()}
  def send_renewal_reminders(contracts) do
    results =
      Enum.map(contracts, fn contract ->
        days_until_notice = Date.diff(
          Date.add(contract.end_date, -notice_period_days(contract.type)),
          Date.utc_today()
        )

        if days_until_notice in [30, 14, 7] do
          NotificationService.send_renewal_reminder(contract, days_until_notice)
          :sent
        else
          :skipped
        end
      end)

    %{
      sent: Enum.count(results, &(&1 == :sent)),
      skipped: Enum.count(results, &(&1 == :skipped))
    }
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `contract_type`
  # also appears in `renewal_term_months/1` below. Both enumerate :monthly,
  # :quarterly, :annual, :biennial — adding a new type requires updating both.
  @spec notice_period_days(contract_type()) :: integer()
  def notice_period_days(contract_type) do
    case contract_type do
      :monthly   -> 14
      :quarterly -> 30
      :annual    -> 60
      :biennial  -> 90
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `contract_type`
  # already appeared in `notice_period_days/1` above. The four contract type atoms
  # are fully repeated, making these functions independently fragile.
  @spec renewal_term_months(contract_type()) :: integer()
  def renewal_term_months(contract_type) do
    case contract_type do
      :monthly   -> 1
      :quarterly -> 3
      :annual    -> 12
      :biennial  -> 24
    end
  end
  # VALIDATION: SMELL END

  @spec valid_type?(atom()) :: boolean()
  def valid_type?(type), do: type in [:monthly, :quarterly, :annual, :biennial]

  @spec shift_months(Date.t(), integer()) :: Date.t()
  defp shift_months(%Date{year: y, month: m, day: d}, months) do
    total = y * 12 + (m - 1) + months
    new_year = div(total, 12)
    new_month = rem(total, 12) + 1
    max_day = Date.days_in_month(%Date{year: new_year, month: new_month, day: 1})
    %Date{year: new_year, month: new_month, day: min(d, max_day)}
  end
end
```

# Annotated Bad Example 15

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `run_payroll/3`, inside the `with` block's `else` clause
- **Affected function(s):** `run_payroll/3`
- **Short explanation:** Payroll processing involves loading the payroll period, fetching employees, computing deductions, calculating net pay, posting to the bank API, and recording a ledger entry. Each step fails differently, yet all errors converge in one `else` block, making debugging and maintenance difficult.

```elixir
defmodule Payroll.PayrollRunner do
  alias Payroll.{Repo, PayrollPeriod, Employee, DeductionEngine, TaxEngine, BankAPI, Ledger}

  require Logger

  def run_payroll(period_id, department_id, initiated_by) do
    with {:ok, period} <- fetch_open_period(period_id),
         {:ok, employees} <- fetch_active_employees(department_id),
         {:ok, deductions} <- DeductionEngine.compute_all(employees, period),
         {:ok, payslips} <- TaxEngine.compute_net(employees, deductions, period),
         {:ok, batch_ref} <- BankAPI.submit_batch(payslips, period),
         {:ok, _entry} <- Ledger.record_payroll(batch_ref, payslips, period, initiated_by) do
      period
      |> PayrollPeriod.changeset(%{status: :processed, batch_ref: batch_ref, processed_by: initiated_by, processed_at: DateTime.utc_now()})
      |> Repo.update()

      Logger.info(
        "Payroll period #{period_id} processed: dept=#{department_id} " <>
          "employees=#{length(employees)} batch=#{batch_ref}"
      )

      {:ok, %{period_id: period_id, batch_ref: batch_ref, employee_count: length(employees)}}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because six pipeline steps each produce distinct errors,
      # all collected into a single `else` block. `:not_found`, `:already_processed`,
      # `:period_locked` come from step 1; `:no_employees` from step 2;
      # `{:deduction_error, _}` from step 3; `{:tax_calculation_error, _}` from step 4;
      # `:bank_api_rejected`, `:bank_api_timeout` from step 5; and `:ledger_write_failed`
      # from step 6 — all without any grouping or attribution in the `else` block.
      {:error, :not_found} ->
        Logger.warning("Payroll period #{period_id} not found")
        {:error, :period_not_found}

      {:error, :already_processed} ->
        Logger.warning("Payroll period #{period_id} already processed")
        {:error, :period_already_processed}

      {:error, :period_locked} ->
        Logger.warning("Payroll period #{period_id} is currently locked by another process")
        {:error, :period_locked}

      {:error, :no_employees} ->
        Logger.warning("No active employees in department #{department_id}")
        {:error, :no_employees}

      {:error, {:deduction_error, reason}} ->
        Logger.error("Deduction computation failed: #{inspect(reason)}")
        {:error, :deduction_error}

      {:error, {:tax_calculation_error, reason}} ->
        Logger.error("Tax calculation failed: #{inspect(reason)}")
        {:error, :tax_engine_error}

      {:error, :bank_api_rejected} ->
        Logger.error("Bank API rejected payroll batch for period #{period_id}")
        {:error, :bank_submission_failed}

      {:error, :bank_api_timeout} ->
        Logger.error("Bank API timed out for payroll period #{period_id}")
        schedule_retry(period_id, department_id, initiated_by)
        {:error, :bank_timeout}

      {:error, :ledger_write_failed} ->
        Logger.error("Ledger record failed for batch — manual reconciliation required")
        {:error, :ledger_error}
      # VALIDATION: SMELL END
    end
  end

  defp fetch_open_period(period_id) do
    case Repo.get(PayrollPeriod, period_id) do
      nil -> {:error, :not_found}
      %PayrollPeriod{status: :processed} -> {:error, :already_processed}
      %PayrollPeriod{locked: true} -> {:error, :period_locked}
      period -> {:ok, period}
    end
  end

  defp fetch_active_employees(department_id) do
    employees =
      Repo.all(
        from e in Employee,
          where: e.department_id == ^department_id and e.status == :active
      )

    if employees == [] do
      {:error, :no_employees}
    else
      {:ok, employees}
    end
  end

  defp schedule_retry(period_id, department_id, initiated_by) do
    %{period_id: period_id, department_id: department_id, initiated_by: initiated_by}
    |> Payroll.RetryWorker.new(schedule_in: 1_800)
    |> Oban.insert()
  end
end
```

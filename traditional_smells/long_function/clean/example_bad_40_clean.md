```elixir
defmodule Finance.ExpenseReportProcessor do
  @moduledoc """
  Processes employee expense report submissions including
  policy checks, multi-currency conversion, and ERP sync.
  """

  require Logger

  alias Finance.{
    ExpenseReport, ExpensePolicy, Receipt,
    CurrencyConverter, ApprovalRouter,
    Ledger, ERPBridge, ReimbursementScheduler, Mailer
  }

  @receipt_required_above_cents 2_500
  @max_single_expense_cents     150_000
  @base_currency                "USD"

  def submit(%ExpenseReport{} = report, opts \\ []) do
    submitter = Keyword.get(opts, :submitter)

    Logger.info("Processing expense report #{report.id} by employee #{report.employee_id}")

    # 1. Load the applicable spending policy
    policy = ExpensePolicy.for_employee(report.employee_id)

    unless policy do
      {:error, :no_policy_found}
    else
      # 2. Validate each expense line against policy
      violations =
        Enum.flat_map(report.line_items, fn item ->
          item_errors = []

          item_errors =
            if item.amount_cents > @max_single_expense_cents,
              do: [{:amount_exceeds_max, item.id} | item_errors],
              else: item_errors

          item_errors =
            if item.category not in policy.allowed_categories,
              do: [{:disallowed_category, item.id, item.category} | item_errors],
              else: item_errors

          category_limit = Map.get(policy.category_limits, item.category, :unlimited)

          item_errors =
            if category_limit != :unlimited and item.amount_cents > category_limit,
              do: [{:category_limit_exceeded, item.id, category_limit} | item_errors],
              else: item_errors

          item_errors
        end)

      if violations != [] do
        {:error, {:policy_violations, violations}}
      else
        # 3. Check receipt attachments
        missing_receipts =
          Enum.filter(report.line_items, fn item ->
            item.amount_cents >= @receipt_required_above_cents and
              not Receipt.attached?(item.id)
          end)

        if missing_receipts != [] do
          {:error, {:missing_receipts, Enum.map(missing_receipts, & &1.id)}}
        else
          # 4. Convert all line items to base currency
          converted_items =
            Enum.map(report.line_items, fn item ->
              if item.currency == @base_currency do
                Map.put(item, :base_amount_cents, item.amount_cents)
              else
                case CurrencyConverter.convert(item.amount_cents, item.currency, @base_currency) do
                  {:ok, converted} ->
                    Map.put(item, :base_amount_cents, converted)

                  {:error, reason} ->
                    Logger.warning("Currency conversion failed: #{inspect(reason)}")
                    Map.put(item, :base_amount_cents, item.amount_cents)
                end
              end
            end)

          total_base_cents = Enum.sum(Enum.map(converted_items, & &1.base_amount_cents))

          # 5. Determine approval routing
          approval_path =
            cond do
              total_base_cents > 500_000 ->
                ApprovalRouter.route(:vp_approval, report.employee_id)

              total_base_cents > 100_000 ->
                ApprovalRouter.route(:manager_plus_finance, report.employee_id)

              true ->
                ApprovalRouter.route(:direct_manager, report.employee_id)
            end

          # 6. Persist updated report with converted totals
          updated_attrs = %{
            line_items:       converted_items,
            total_cents:      total_base_cents,
            currency:         @base_currency,
            status:           :pending_approval,
            approval_path:    approval_path,
            submitted_at:     DateTime.utc_now(),
            submitted_by:     submitter
          }

          case ExpenseReport.update(report.id, updated_attrs) do
            {:error, reason} ->
              Logger.error("Report update failed #{report.id}: #{inspect(reason)}")
              {:error, :persistence_failed}

            {:ok, saved_report} ->
              # 7. Create draft ledger entry
              Ledger.create_draft(%{
                reference:   "EXP-#{report.id}",
                employee_id: report.employee_id,
                amount:      total_base_cents,
                currency:    @base_currency,
                category:    :employee_expense,
                period:      report.expense_period,
                created_at:  DateTime.utc_now()
              })

              # 8. Sync to ERP
              Task.start(fn ->
                case ERPBridge.post_expense(saved_report) do
                  {:ok, erp_ref} ->
                    ExpenseReport.set_erp_reference(saved_report.id, erp_ref)

                  {:error, reason} ->
                    Logger.error("ERP sync failed for #{saved_report.id}: #{inspect(reason)}")
                end
              end)

              # 9. Schedule reimbursement for auto-approved small amounts
              if total_base_cents <= policy.auto_approve_threshold_cents do
                ReimbursementScheduler.schedule(%{
                  report_id:    saved_report.id,
                  employee_id:  report.employee_id,
                  amount_cents: total_base_cents,
                  pay_date:     Date.add(Date.utc_today(), policy.reimbursement_days)
                })
              end

              # 10. Notify the employee
              next_approver = List.first(approval_path)
              approver_name = if next_approver, do: next_approver.name, else: "your manager"

              email_body = """
              Hi #{report.employee_name},

              Your expense report ##{report.id} has been submitted successfully.

              Total (USD)  : $#{Float.round(total_base_cents / 100, 2)}
              Status       : Pending approval by #{approver_name}
              Items        : #{length(report.line_items)}

              You will be notified once it is approved.
              """

              case Mailer.send_email(report.employee_email, "Expense Report Submitted", email_body) do
                {:ok, _}         -> :ok
                {:error, reason} -> Logger.warning("Notification failed: #{inspect(reason)}")
              end

              {:ok, saved_report}
          end
        end
      end
    end
  end
end
```

# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `seed_initial_risk_scores/0`, `compute_risk_score/1`
- **Affected functions:** `change/0`, `seed_initial_risk_scores/0`, `compute_risk_score/1`
- **Short explanation:** This migration adds `risk_score` and `risk_band` columns to `loan_applications` (structural change) and then computes heuristic risk scores for every existing application row using application fields (data manipulation). Embedding risk-scoring business logic inside a migration conflates schema evolution with domain computation.

---

```elixir
defmodule Lending.Repo.Migrations.AddRiskScoreToLoanApplications do
  use Ecto.Migration

  import Ecto.Query
  alias Lending.Repo

  @high_risk_threshold   70
  @medium_risk_threshold 40

  def change do
    alter table("loan_applications") do
      add :risk_score, :integer, null: true
      add :risk_band,  :string,  null: true, size: 20
    end

    create index("loan_applications", [:risk_band])
    create index("loan_applications", [:risk_score])
    create index("loan_applications", [:risk_band, :status])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration reads existing loan
    # application fields and applies a scoring algorithm to compute and persist
    # risk_score and risk_band. Encoding domain business logic (risk scoring) and
    # writing computed results inside a migration module is data manipulation that
    # must be separated into a dedicated Mix task.
    seed_initial_risk_scores()
    # VALIDATION: SMELL END
  end

  defp seed_initial_risk_scores do
    from(la in "loan_applications",
      where: is_nil(la.risk_score),
      select: %{
        id:                 la.id,
        requested_amount:   la.requested_amount,
        annual_income:      la.annual_income,
        existing_debt:      la.existing_debt,
        credit_score:       la.credit_score,
        employment_months:  la.employment_months
      }
    )
    |> Repo.all()
    |> Enum.each(fn application ->
      {score, band} = compute_risk_score(application)

      from(la in "loan_applications", where: la.id == ^application.id)
      |> Repo.update_all(set: [risk_score: score, risk_band: band])
    end)
  end

  defp compute_risk_score(%{
    requested_amount:  amount,
    annual_income:     income,
    existing_debt:     debt,
    credit_score:      credit,
    employment_months: emp_months
  }) do
    dti_score =
      if income && income > 0 do
        debt_amount = debt || 0
        dti = debt_amount / income
        cond do
          dti > 0.5  -> 30
          dti > 0.35 -> 20
          dti > 0.20 -> 10
          true       -> 0
        end
      else
        30
      end

    credit_score =
      case credit do
        c when is_integer(c) and c >= 750 -> 0
        c when is_integer(c) and c >= 700 -> 10
        c when is_integer(c) and c >= 650 -> 20
        c when is_integer(c) and c >= 600 -> 30
        _                                 -> 40
      end

    employment_score =
      case emp_months do
        m when is_integer(m) and m >= 24 -> 0
        m when is_integer(m) and m >= 12 -> 10
        m when is_integer(m) and m >= 6  -> 20
        _                                -> 30
      end

    amount_score =
      cond do
        is_nil(amount) or amount <= 5_000   -> 0
        amount <= 25_000                    -> 10
        amount <= 75_000                    -> 20
        true                                -> 30
      end

    total = dti_score + credit_score + employment_score + amount_score

    band =
      cond do
        total >= @high_risk_threshold   -> "high"
        total >= @medium_risk_threshold -> "medium"
        true                            -> "low"
      end

    {total, band}
  end
end
```

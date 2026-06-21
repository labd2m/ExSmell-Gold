```elixir
defmodule Mix.Tasks.Db.Seed.Plans do
  @moduledoc """
  Seeds the `subscription_plans` table with the canonical plan definitions.

  This task is idempotent: existing plans are matched on `code` and updated
  in place; new plans are inserted. It is safe to run repeatedly in any
  environment without causing duplicate rows.

  ## Usage

      mix db.seed.plans

  """

  use Mix.Task

  alias Commerce.Repo
  alias Commerce.Billing.Plan

  @shortdoc "Seeds canonical subscription plan records into the database"

  @plans [
    %{
      code: "free",
      name: "Free",
      price_cents: 0,
      max_seats: 1,
      features: ["basic_access"]
    },
    %{
      code: "pro",
      name: "Professional",
      price_cents: 2_900,
      max_seats: 5,
      features: ["basic_access", "advanced_reports", "api_access"]
    },
    %{
      code: "enterprise",
      name: "Enterprise",
      price_cents: 9_900,
      max_seats: 50,
      features: ["basic_access", "advanced_reports", "api_access", "sso", "dedicated_support"]
    }
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Mix.shell().info("Seeding subscription plans...")

    results = Enum.map(@plans, &upsert_plan/1)
    print_summary(results)
  end

  defp upsert_plan(%{code: code} = attrs) do
    case Repo.get_by(Plan, code: code) do
      nil -> insert_plan(attrs)
      existing -> update_plan(existing, attrs)
    end
  end

  defp insert_plan(%{code: code} = attrs) do
    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
    |> report_outcome(:created, code)
  end

  defp update_plan(%Plan{} = plan, attrs) do
    plan
    |> Plan.changeset(attrs)
    |> Repo.update()
    |> report_outcome(:updated, plan.code)
  end

  defp report_outcome({:ok, record}, action, _code) do
    Mix.shell().info("  [#{action}] #{record.code}")
    action
  end

  defp report_outcome({:error, changeset}, _action, code) do
    errors = format_errors(changeset)
    Mix.shell().error("  [failed] #{code} — #{errors}")
    :failed
  end

  defp format_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  defp print_summary(results) do
    counts = Enum.frequencies(results)

    Mix.shell().info("""

    Seeding complete.
      Created : #{Map.get(counts, :created, 0)}
      Updated : #{Map.get(counts, :updated, 0)}
      Failed  : #{Map.get(counts, :failed, 0)}
    """)
  end
end
```

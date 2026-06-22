```elixir
defmodule Mix.Tasks.Store.SeedProducts do
  @moduledoc """
  Seeds the product catalog with fixture data for development and staging
  environments.

  This task is intentionally separated from database migrations. It performs
  data population only and makes no structural schema changes. Running it
  multiple times is safe because existing products are updated rather than
  duplicated.

  ## Usage

      mix store.seed_products
      mix store.seed_products --env staging

  ## Options

    * `--env` - Target environment label appended to log output (default: "development")
  """
  use Mix.Task

  require Logger

  alias Store.Catalog

  @shortdoc "Seeds initial product catalog fixtures into the database"

  @fixtures [
    %{sku: "BOOK-001", name: "Elixir in Action", price_cents: 3_999, currency: "USD", category: "books"},
    %{sku: "BOOK-002", name: "Programming Phoenix", price_cents: 4_499, currency: "USD", category: "books"},
    %{sku: "BOOK-003", name: "Designing Elixir Systems", price_cents: 3_299, currency: "USD", category: "books"},
    %{sku: "HW-001", name: "Mechanical Keyboard", price_cents: 12_999, currency: "USD", category: "hardware"},
    %{sku: "HW-002", name: "USB-C Hub", price_cents: 4_999, currency: "USD", category: "hardware"},
    %{sku: "HW-003", name: "Wrist Rest", price_cents: 1_899, currency: "USD", category: "hardware"}
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    env = parse_env_option(args)

    Logger.info("Starting product seed", environment: env, fixture_count: length(@fixtures))

    results = Enum.map(@fixtures, &upsert_product/1)

    report_seed_results(results)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp parse_env_option(args) do
    {parsed, _argv, _errors} = OptionParser.parse(args, strict: [env: :string])
    Keyword.get(parsed, :env, "development")
  end

  defp upsert_product(attrs) do
    case Catalog.find_by_sku(attrs.sku) do
      {:ok, existing} -> Catalog.update_product(existing, attrs)
      {:error, :not_found} -> Catalog.create_product(attrs)
    end
  end

  defp report_seed_results(results) do
    {succeeded, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

    Logger.info("Product seed complete",
      succeeded: length(succeeded),
      failed: length(failed)
    )

    log_failures(failed)

    if length(failed) > 0 do
      Mix.raise("Seed completed with #{length(failed)} failure(s). Review logs for details.")
    end
  end

  defp log_failures([]), do: :ok

  defp log_failures(failures) do
    Enum.each(failures, fn {:error, changeset} ->
      Logger.error("Product seed failure", errors: inspect(changeset.errors))
    end)
  end
end
```

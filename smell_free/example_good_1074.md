**File:** `example_good_1074.md`

```elixir
defmodule Mix.Tasks.Db.Seed do
  @shortdoc "Seeds the database with initial reference and demo data."

  @moduledoc """
  Idempotent seed task that populates essential reference data and
  (in non-production environments) a small set of demo records.
  Existing records are matched by unique keys and skipped rather than duplicated.
  """

  use Mix.Task

  alias Seeder.{ReferenceData, DemoData, SeedResult}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [demo: :boolean, quiet: :boolean],
        aliases: [d: :demo, q: :quiet]
      )

    include_demo = Keyword.get(opts, :demo, Mix.env() != :prod)
    quiet = Keyword.get(opts, :quiet, false)

    results = seed_all(include_demo)

    unless quiet do
      print_summary(results)
    end

    if Enum.any?(results, &match?({:error, _}, &1)) do
      Mix.raise("Seeding completed with errors. Review output above.")
    end
  end

  defp seed_all(include_demo) do
    reference_results = seed_reference_data()

    demo_results =
      if include_demo do
        seed_demo_data()
      else
        []
      end

    reference_results ++ demo_results
  end

  defp seed_reference_data do
    [
      {"plan:free", &ReferenceData.upsert_plan(&1, "Free", 0)},
      {"plan:starter", &ReferenceData.upsert_plan(&1, "Starter", 900)},
      {"plan:pro", &ReferenceData.upsert_plan(&1, "Pro", 2900)},
      {"plan:enterprise", &ReferenceData.upsert_plan(&1, "Enterprise", 9900)},
      {"feature:api_access", &ReferenceData.upsert_feature(&1, "API Access", :api_access)},
      {"feature:webhooks", &ReferenceData.upsert_feature(&1, "Webhooks", :webhooks)},
      {"feature:sso", &ReferenceData.upsert_feature(&1, "Single Sign-On", :sso)}
    ]
    |> Enum.map(&run_seeder/1)
  end

  defp seed_demo_data do
    [
      {"demo:org:acme", &DemoData.upsert_organization(&1, "Acme Corp", "acme")},
      {"demo:org:globex", &DemoData.upsert_organization(&1, "Globex Inc", "globex")},
      {"demo:user:alice", &DemoData.upsert_user(&1, "alice@acme.example", "acme")},
      {"demo:user:bob", &DemoData.upsert_user(&1, "bob@globex.example", "globex")}
    ]
    |> Enum.map(&run_seeder/1)
  end

  defp run_seeder({label, seeder_fn}) do
    case seeder_fn.(label) do
      {:ok, result} ->
        {:ok, %SeedResult{label: label, action: result.action, record_id: result.id}}

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        {:error, %SeedResult{label: label, errors: errors}}
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp print_summary(results) do
    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    err_count = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("\nSeed complete: #{ok_count} succeeded, #{err_count} failed.")

    results
    |> Enum.filter(&match?({:error, _}, &1))
    |> Enum.each(fn {:error, %{label: label, errors: errors}} ->
      Mix.shell().error("  FAILED [#{label}]: #{inspect(errors)}")
    end)
  end
end

defmodule Seeder.SeedResult do
  @moduledoc false
  defstruct [:label, :action, :record_id, errors: []]

  @type t :: %__MODULE__{
          label: String.t(),
          action: :inserted | :updated | :skipped | nil,
          record_id: term(),
          errors: map()
        }
end
```

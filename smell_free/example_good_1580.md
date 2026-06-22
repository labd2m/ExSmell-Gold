```elixir
defmodule Mix.Tasks.Commerce.BackfillProductSlugs do
  @moduledoc """
  Backfills URL-safe slugs for all products that have a nil slug field.

  This task is intentionally separate from schema migrations and is safe
  to re-run: products that already have a slug are skipped.

      mix commerce.backfill_product_slugs
      mix commerce.backfill_product_slugs --dry-run
      mix commerce.backfill_product_slugs --batch-size 500

  """

  use Mix.Task

  import Ecto.Query

  alias Commerce.Repo
  alias Commerce.Catalog.Product

  @shortdoc "Backfills missing URL slugs on product records"

  @default_batch_size 200

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _, _} =
      OptionParser.parse(args, strict: [dry_run: :boolean, batch_size: :integer])

    dry_run = Keyword.get(parsed, :dry_run, false)
    batch_size = Keyword.get(parsed, :batch_size, @default_batch_size)

    Mix.shell().info("Starting slug backfill (dry_run=#{dry_run}, batch_size=#{batch_size})")

    {total, updated} = process_in_batches(batch_size, dry_run)

    Mix.shell().info("Done. Processed #{total} products, updated #{updated}.")
  end

  defp process_in_batches(batch_size, dry_run) do
    stream =
      Product
      |> where([p], is_nil(p.slug))
      |> select([p], p)
      |> Repo.stream()

    Repo.transaction(fn ->
      stream
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce({0, 0}, fn batch, {total_acc, updated_acc} ->
        updates = Enum.map(batch, &build_slug_update/1)

        {affected, _} =
          if dry_run do
            {0, nil}
          else
            Repo.update_all(
              from(p in Product, where: p.id in ^Enum.map(updates, & &1.id)),
              set: [slug: nil]
            )
            apply_batch_updates(updates)
          end

        {total_acc + length(batch), updated_acc + affected}
      end)
    end)
    |> case do
      {:ok, counts} -> counts
      {:error, reason} -> Mix.raise("Backfill failed: #{inspect(reason)}")
    end
  end

  defp apply_batch_updates(updates) do
    Enum.reduce(updates, {0, []}, fn %{id: id, slug: slug}, {count, errors} ->
      Product
      |> Repo.get(id)
      |> case do
        nil ->
          {count, errors}

        product ->
          case Repo.update(Product.changeset(product, %{slug: slug})) do
            {:ok, _} -> {count + 1, errors}
            {:error, cs} -> {count, [cs | errors]}
          end
      end
    end)
  end

  defp build_slug_update(%Product{id: id, name: name}) do
    %{id: id, slug: slugify(name)}
  end

  defp slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
```

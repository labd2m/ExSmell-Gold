```elixir
defmodule MyApp.DataPipeline.CSVIngester do
  @moduledoc """
  Ingests a product catalog CSV file in a memory-efficient streaming
  fashion, applying field validation and transformation to each row
  before bulk-inserting batches into the database via Ecto.

  Rows that fail validation are collected and returned alongside the
  success count so callers have full visibility into partial failures
  without the pipeline halting entirely.
  """

  alias MyApp.Repo
  alias MyApp.Catalog.Product

  import Ecto.Query, warn: false

  @batch_size 250
  @required_columns ~w(sku name price_cents category_slug)

  @type row_number :: pos_integer()
  @type ingest_error :: %{row: row_number(), reason: term()}

  @type result :: %{
          inserted: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [ingest_error()]
        }

  @doc """
  Streams `file_path` as CSV, validates and transforms each row, and
  inserts valid rows in batches of #{@batch_size}. Returns an `{:ok, result}`
  tuple summarising the run, or `{:error, :file_not_found}`.
  """
  @spec ingest(String.t()) :: {:ok, result()} | {:error, :file_not_found}
  def ingest(file_path) when is_binary(file_path) do
    if File.exists?(file_path) do
      {:ok, run_pipeline(file_path)}
    else
      {:error, :file_not_found}
    end
  end

  @spec run_pipeline(String.t()) :: result()
  defp run_pipeline(file_path) do
    file_path
    |> stream_rows()
    |> Stream.with_index(2)
    |> Stream.map(fn {row, line} -> validate_and_cast(row, line) end)
    |> Enum.reduce(
      %{pending: [], inserted: 0, skipped: 0, errors: []},
      &accumulate_row/2
    )
    |> flush_pending()
    |> Map.drop([:pending])
  end

  @spec stream_rows(String.t()) :: Enumerable.t()
  defp stream_rows(path) do
    path
    |> File.stream!()
    |> CSV.decode(headers: true, strip_fields: true)
    |> Stream.filter(&match?({:ok, _}, &1))
    |> Stream.map(fn {:ok, row} -> row end)
  end

  @spec validate_and_cast(map(), row_number()) ::
          {:ok, map()} | {:error, ingest_error()}
  defp validate_and_cast(row, line) do
    with :ok <- check_required_fields(row, line),
         {:ok, price_cents} <- parse_integer(row["price_cents"], :price_cents, line) do
      attrs = %{
        sku: String.trim(row["sku"]),
        name: String.trim(row["name"]),
        price_cents: price_cents,
        category_slug: String.trim(row["category_slug"]),
        available: parse_boolean(row["available"])
      }

      {:ok, attrs}
    end
  end

  @spec check_required_fields(map(), row_number()) :: :ok | {:error, ingest_error()}
  defp check_required_fields(row, line) do
    missing = Enum.reject(@required_columns, &(Map.get(row, &1, "") != ""))

    if missing == [] do
      :ok
    else
      {:error, %{row: line, reason: {:missing_fields, missing}}}
    end
  end

  @spec parse_integer(String.t() | nil, atom(), row_number()) ::
          {:ok, integer()} | {:error, ingest_error()}
  defp parse_integer(str, field, line) do
    case Integer.parse(to_string(str)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, %{row: line, reason: {:invalid_integer, field}}}
    end
  end

  @spec parse_boolean(String.t() | nil) :: boolean()
  defp parse_boolean(val) when val in ~w(true 1 yes), do: true
  defp parse_boolean(_), do: false

  @spec accumulate_row(
          {:ok, map()} | {:error, ingest_error()},
          map()
        ) :: map()
  defp accumulate_row({:error, err}, acc) do
    %{acc | errors: [err | acc.errors], skipped: acc.skipped + 1}
  end

  defp accumulate_row({:ok, attrs}, acc) do
    pending = [attrs | acc.pending]

    if length(pending) >= @batch_size do
      inserted = insert_batch(pending)
      %{acc | pending: [], inserted: acc.inserted + inserted}
    else
      %{acc | pending: pending}
    end
  end

  @spec flush_pending(map()) :: map()
  defp flush_pending(%{pending: []} = acc), do: acc

  defp flush_pending(acc) do
    inserted = insert_batch(acc.pending)
    %{acc | pending: [], inserted: acc.inserted + inserted}
  end

  @spec insert_batch([map()]) :: non_neg_integer()
  defp insert_batch(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stamped = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))
    {count, _} = Repo.insert_all(Product, stamped, on_conflict: :nothing)
    count
  end
end
```

```elixir
defmodule MyApp.Catalog.ProductImporter do
  @moduledoc """
  Imports product records from an external supplier feed delivered as a
  JSON array. Each record is validated through an Ecto embedded schema
  before being upserted into the catalog. Import results are summarised
  into a structured report that callers can log or surface to operators
  without inspecting raw changesets.

  The entire import runs inside a single database transaction. If the
  transaction is rolled back due to a database error, no partial state
  is left behind.
  """

  alias MyApp.Repo
  alias MyApp.Catalog.Product
  alias MyApp.Catalog.SupplierRecord

  @type import_report :: %{
          total: non_neg_integer(),
          inserted: non_neg_integer(),
          updated: non_neg_integer(),
          rejected: non_neg_integer(),
          errors: [%{sku: String.t(), reasons: [String.t()]}]
        }

  @doc """
  Parses `json_body`, validates each record, and upserts valid products.
  Returns `{:ok, report}` summarising the run, or `{:error, :invalid_json}`
  when the payload cannot be decoded.
  """
  @spec import_feed(String.t()) :: {:ok, import_report()} | {:error, :invalid_json}
  def import_feed(json_body) when is_binary(json_body) do
    case Jason.decode(json_body) do
      {:ok, records} when is_list(records) ->
        {:ok, run_import(records)}

      _ ->
        {:error, :invalid_json}
    end
  end

  @spec run_import([map()]) :: import_report()
  defp run_import(records) do
    {valid, rejected} = partition_records(records)

    {inserted, updated} =
      Repo.transaction(fn -> upsert_all(valid) end)
      |> case do
        {:ok, counts} -> counts
        {:error, _} -> {0, 0}
      end

    %{
      total: length(records),
      inserted: inserted,
      updated: updated,
      rejected: rejected |> length(),
      errors: build_error_list(rejected)
    }
  end

  @spec partition_records([map()]) :: {[map()], [{map(), Ecto.Changeset.t()}]}
  defp partition_records(records) do
    Enum.reduce(records, {[], []}, fn raw, {valid, invalid} ->
      changeset = SupplierRecord.changeset(%SupplierRecord{}, raw)

      if changeset.valid? do
        {[Ecto.Changeset.apply_changes(changeset) | valid], invalid}
      else
        {valid, [{raw, changeset} | invalid]}
      end
    end)
  end

  @spec upsert_all([SupplierRecord.t()]) :: {non_neg_integer(), non_neg_integer()}
  defp upsert_all(records) do
    Enum.reduce(records, {0, 1}, fn record, {ins, upd} ->
      existing = Repo.get_by(Product, sku: record.sku)

      case upsert_product(existing, record) do
        {:ok, %{__meta__: %{state: :loaded}}} -> {ins, upd + 1}
        {:ok, _} -> {ins + 1, upd}
        {:error, _} -> {ins, upd}
      end
    end)
  end

  @spec upsert_product(Product.t() | nil, SupplierRecord.t()) ::
          {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  defp upsert_product(nil, record) do
    %Product{}
    |> Product.changeset(Map.from_struct(record))
    |> Repo.insert()
  end

  defp upsert_product(existing, record) do
    existing
    |> Product.changeset(Map.from_struct(record))
    |> Repo.update()
  end

  @spec build_error_list([{map(), Ecto.Changeset.t()}]) :: [map()]
  defp build_error_list(rejected) do
    Enum.map(rejected, fn {raw, changeset} ->
      reasons =
        Enum.map(changeset.errors, fn {field, {msg, _}} -> "#{field}: #{msg}" end)

      %{sku: Map.get(raw, "sku", "unknown"), reasons: reasons}
    end)
  end
end
```

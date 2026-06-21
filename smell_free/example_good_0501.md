# File: `example_good_501.md`

```elixir
defmodule Catalog.ImportPipeline do
  @moduledoc """
  Validates and imports product records from a structured list of raw
  maps, applying field coercions, uniqueness deduplication, and
  Ecto changesets before persistence.

  The pipeline runs in three passes: validate, deduplicate, upsert.
  Each pass is independent so callers can run a dry-run validation
  without touching the database.
  """

  alias Catalog.{Product, Repo}
  import Ecto.Query, warn: false

  @type raw_product :: %{String.t() => term()}

  @type import_result :: %{
          inserted: non_neg_integer(),
          updated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [%{record: raw_product(), reason: term()}]
        }

  @doc """
  Validates, deduplicates, and upserts `raw_products` into the catalog.

  Returns a summary of inserted, updated, skipped, and errored records.
  """
  @spec run([raw_product()]) :: import_result()
  def run(raw_products) when is_list(raw_products) do
    {valid, errors} = validate_all(raw_products)
    deduplicated = deduplicate(valid)
    {inserted, updated, upsert_errors} = upsert_all(deduplicated)

    %{
      inserted: inserted,
      updated: updated,
      skipped: length(valid) - length(deduplicated),
      errors: errors ++ upsert_errors
    }
  end

  @doc """
  Validates `raw_products` without writing to the database.

  Returns `{valid_changesets, error_entries}`.
  """
  @spec validate_only([raw_product()]) ::
          {[Ecto.Changeset.t()], [%{record: raw_product(), reason: term()}]}
  def validate_only(raw_products) when is_list(raw_products) do
    validate_all(raw_products)
  end

  defp validate_all(raw_products) do
    Enum.reduce(raw_products, {[], []}, fn raw, {valid_acc, error_acc} ->
      attrs = coerce_attrs(raw)
      changeset = Product.import_changeset(%Product{}, attrs)

      if changeset.valid? do
        {[changeset | valid_acc], error_acc}
      else
        error = %{record: raw, reason: changeset.errors}
        {valid_acc, [error | error_acc]}
      end
    end)
    |> then(fn {valid, errors} ->
      {Enum.reverse(valid), Enum.reverse(errors)}
    end)
  end

  defp deduplicate(changesets) do
    changesets
    |> Enum.group_by(fn cs -> Ecto.Changeset.get_field(cs, :sku) end)
    |> Enum.map(fn {_sku, [latest | _rest]} -> latest end)
  end

  defp upsert_all(changesets) do
    Enum.reduce(changesets, {0, 0, []}, fn changeset, {ins, upd, errs} ->
      sku = Ecto.Changeset.get_field(changeset, :sku)

      case upsert_product(sku, changeset) do
        {:ok, %{__meta__: %{state: :loaded}}} -> {ins, upd + 1, errs}
        {:ok, _} -> {ins + 1, upd, errs}
        {:error, reason} ->
          err = %{record: changeset.params, reason: reason}
          {ins, upd, [err | errs]}
      end
    end)
    |> then(fn {ins, upd, errs} -> {ins, upd, Enum.reverse(errs)} end)
  end

  defp upsert_product(sku, changeset) do
    case Repo.get_by(Product, sku: sku) do
      nil ->
        Repo.insert(changeset)

      existing ->
        existing
        |> Product.import_changeset(changeset.changes)
        |> Repo.update()
    end
  end

  defp coerce_attrs(raw) do
    %{
      sku: to_string_or_nil(Map.get(raw, "sku") || Map.get(raw, :sku)),
      name: to_string_or_nil(Map.get(raw, "name") || Map.get(raw, :name)),
      description: to_string_or_nil(Map.get(raw, "description") || Map.get(raw, :description)),
      price_cents: to_integer_or_nil(Map.get(raw, "price_cents") || Map.get(raw, :price_cents)),
      currency: to_string_or_nil(Map.get(raw, "currency") || Map.get(raw, :currency)),
      active: to_boolean(Map.get(raw, "active") || Map.get(raw, :active))
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  defp to_integer_or_nil(nil), do: nil
  defp to_integer_or_nil(v) when is_integer(v), do: v
  defp to_integer_or_nil(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end
  defp to_integer_or_nil(_), do: nil

  defp to_boolean(nil), do: true
  defp to_boolean(true), do: true
  defp to_boolean(false), do: false
  defp to_boolean("true"), do: true
  defp to_boolean("false"), do: false
  defp to_boolean(_), do: true
end
```

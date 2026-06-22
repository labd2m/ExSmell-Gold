```elixir
defmodule MyApp.DataPipeline.RecordDeduplicator do
  @moduledoc """
  Removes duplicate records from a stream before they reach the database.
  Deduplication is performed using a configurable key extractor function
  that produces a string fingerprint per record. Records with identical
  fingerprints within the same batch are collapsed to the most recent
  occurrence by default.

  The deduplicator is purely functional — it operates on in-memory lists
  and produces a deduplicated list suitable for bulk insert.
  """

  @type record :: map()
  @type fingerprint :: String.t()
  @type key_fn :: (record() -> fingerprint())
  @type merge_fn :: (record(), record() -> record())

  @doc """
  Deduplicates `records` using `key_fn` to derive a fingerprint per
  record. When duplicates are found, `merge_fn` selects which record
  to keep (defaults to keeping the last occurrence).
  """
  @spec deduplicate([record()], key_fn(), merge_fn() | nil) :: [record()]
  def deduplicate(records, key_fn, merge_fn \\ nil)
      when is_list(records) and is_function(key_fn, 1) do
    resolver = merge_fn || fn _older, newer -> newer end

    {deduped, _seen} =
      Enum.reduce(records, {%{}, %{}}, fn record, {acc, order} ->
        key = key_fn.(record)

        case Map.get(acc, key) do
          nil ->
            idx = map_size(order)
            {Map.put(acc, key, record), Map.put(order, key, idx)}

          existing ->
            merged = resolver.(existing, record)
            {Map.put(acc, key, merged), order}
        end
      end)

    deduped
    |> Enum.sort_by(fn {_k, _v} -> 0 end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  @doc """
  Returns a summary map with `:original_count`, `:deduped_count`, and
  `:duplicates_removed` for a deduplication run.
  """
  @spec summarise([record()], [record()]) :: map()
  def summarise(original, deduped) when is_list(original) and is_list(deduped) do
    removed = length(original) - length(deduped)

    %{
      original_count: length(original),
      deduped_count: length(deduped),
      duplicates_removed: removed
    }
  end

  @doc """
  Builds a composite fingerprint from a list of field paths using
  dot-separated key access.
  """
  @spec field_fingerprint([String.t()]) :: key_fn()
  def field_fingerprint(fields) when is_list(fields) do
    fn record ->
      fields
      |> Enum.map(fn field ->
        record
        |> get_in(String.split(field, ".") |> Enum.map(&Access.key(&1, nil)))
        |> to_string()
      end)
      |> Enum.join("|")
    end
  end

  @doc """
  Builds a fingerprint function that hashes the JSON encoding of
  the specified `fields` for a stable, compact fingerprint.
  """
  @spec hash_fingerprint([String.t()]) :: key_fn()
  def hash_fingerprint(fields) when is_list(fields) do
    raw_fn = field_fingerprint(fields)

    fn record ->
      raw = raw_fn.(record)
      :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    end
  end
end
```

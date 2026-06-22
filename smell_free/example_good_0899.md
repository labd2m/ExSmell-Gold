# File: `example_good_899.md`

```elixir
defmodule DataPipeline.JsonTransformer do
  @moduledoc """
  Transforms JSON-like map documents by applying a declarative set of
  field operations: rename, extract, drop, set, and compute.

  Transformations are described as a list of operation structs and
  applied in order. Each operation is independent so the pipeline can
  be assembled from reusable building blocks at the call site.
  """

  @type field_path :: [String.t() | atom()]
  @type transform_fn :: (term() -> term())

  @type operation ::
          {:rename, field_path(), field_path()}
          | {:extract, field_path(), field_path()}
          | {:drop, [field_path()]}
          | {:set, field_path(), term()}
          | {:compute, field_path(), (map() -> term())}
          | {:flatten, field_path(), field_path()}

  @type transform_result :: {:ok, map()} | {:error, {operation(), term()}}

  @doc """
  Applies `operations` to `document` in sequence.

  Returns `{:ok, transformed}` or `{:error, {failing_op, reason}}`
  on the first operation that raises.
  """
  @spec transform(map(), [operation()]) :: transform_result()
  def transform(document, operations) when is_map(document) and is_list(operations) do
    Enum.reduce_while(operations, {:ok, document}, fn op, {:ok, doc} ->
      case apply_op(op, doc) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, {op, reason}}}
      end
    end)
  end

  @doc """
  Transforms a list of documents, returning each result individually.
  Failures on individual documents do not stop the batch.
  """
  @spec transform_batch([map()], [operation()]) :: [transform_result()]
  def transform_batch(documents, operations)
      when is_list(documents) and is_list(operations) do
    Enum.map(documents, &transform(&1, operations))
  end

  defp apply_op({:rename, from_path, to_path}, doc) do
    case fetch_nested(doc, from_path) do
      {:ok, value} ->
        updated = delete_nested(doc, from_path)
        {:ok, put_nested(updated, to_path, value)}

      :error ->
        {:ok, doc}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp apply_op({:extract, source_path, dest_path}, doc) do
    case fetch_nested(doc, source_path) do
      {:ok, value} -> {:ok, put_nested(doc, dest_path, value)}
      :error -> {:ok, doc}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp apply_op({:drop, paths}, doc) when is_list(paths) do
    updated = Enum.reduce(paths, doc, &delete_nested(&2, &1))
    {:ok, updated}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp apply_op({:set, path, value}, doc) do
    {:ok, put_nested(doc, path, value)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp apply_op({:compute, dest_path, derive_fn}, doc) when is_function(derive_fn, 1) do
    value = derive_fn.(doc)
    {:ok, put_nested(doc, dest_path, value)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp apply_op({:flatten, source_path, dest_prefix}, doc) do
    case fetch_nested(doc, source_path) do
      {:ok, nested_map} when is_map(nested_map) ->
        without_source = delete_nested(doc, source_path)
        flattened = Enum.reduce(nested_map, without_source, fn {key, val}, acc ->
          dest = dest_prefix ++ [to_string(key)]
          put_nested(acc, dest, val)
        end)

        {:ok, flattened}

      {:ok, _not_a_map} ->
        {:ok, doc}

      :error ->
        {:ok, doc}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_nested(doc, [key]) do
    string_key = to_string(key)
    case Map.fetch(doc, key) do
      {:ok, _} = ok -> ok
      :error -> Map.fetch(doc, string_key)
    end
  end

  defp fetch_nested(doc, [key | rest]) do
    string_key = to_string(key)
    child = Map.get(doc, key) || Map.get(doc, string_key)
    if is_map(child), do: fetch_nested(child, rest), else: :error
  end

  defp put_nested(doc, [key], value) do
    Map.put(doc, to_string(key), value)
  end

  defp put_nested(doc, [key | rest], value) do
    str_key = to_string(key)
    child = Map.get(doc, str_key, %{})
    updated_child = if is_map(child), do: put_nested(child, rest, value), else: put_nested(%{}, rest, value)
    Map.put(doc, str_key, updated_child)
  end

  defp delete_nested(doc, [key]) do
    str_key = to_string(key)
    doc |> Map.delete(key) |> Map.delete(str_key)
  end

  defp delete_nested(doc, [key | rest]) do
    str_key = to_string(key)
    case Map.fetch(doc, str_key) do
      {:ok, child} when is_map(child) ->
        Map.put(doc, str_key, delete_nested(child, rest))
      _ ->
        doc
    end
  end
end
```

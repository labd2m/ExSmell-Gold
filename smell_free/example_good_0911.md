```elixir
defmodule Data.JSONPatch do
  @moduledoc """
  Applies RFC 6902 JSON Patch operations to Elixir maps. Supports the
  `add`, `remove`, `replace`, `move`, `copy`, and `test` operations.
  The `test` operation halts the patch with an error if the target value
  does not match, providing transactional semantics over the full
  operation list. All functions are pure.
  """

  @type operation ::
          %{op: String.t(), path: String.t(), value: term()}
          | %{op: String.t(), path: String.t(), from: String.t()}
  @type patch_result :: {:ok, map()} | {:error, String.t()}

  @doc """
  Applies the list of `operations` to `document` in order. Stops and
  returns an error on the first failing operation.
  """
  @spec apply(map(), [operation()]) :: patch_result()
  def apply(document, operations) when is_map(document) and is_list(operations) do
    Enum.reduce_while(operations, {:ok, document}, fn op, {:ok, doc} ->
      case apply_op(doc, op) do
        {:ok, new_doc} -> {:cont, {:ok, new_doc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc "Parses a JSON Pointer string into a list of path keys."
  @spec parse_pointer(String.t()) :: [String.t()]
  def parse_pointer(""), do: []
  def parse_pointer("/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.map(&String.replace(&1, "~1", "/"))
    |> Enum.map(&String.replace(&1, "~0", "~"))
  end
  def parse_pointer(pointer), do: [pointer]

  defp apply_op(doc, %{"op" => "add", "path" => path, "value" => value}) do
    set_at(doc, parse_pointer(path), value)
  end

  defp apply_op(doc, %{"op" => "remove", "path" => path}) do
    delete_at(doc, parse_pointer(path))
  end

  defp apply_op(doc, %{"op" => "replace", "path" => path, "value" => value}) do
    pointer = parse_pointer(path)
    case get_at(doc, pointer) do
      {:ok, _} -> set_at(doc, pointer, value)
      :error -> {:error, "path not found: #{path}"}
    end
  end

  defp apply_op(doc, %{"op" => "test", "path" => path, "value" => expected}) do
    case get_at(doc, parse_pointer(path)) do
      {:ok, ^expected} -> {:ok, doc}
      {:ok, actual} -> {:error, "test failed: expected #{inspect(expected)}, got #{inspect(actual)}"}
      :error -> {:error, "test failed: path not found: #{path}"}
    end
  end

  defp apply_op(doc, %{"op" => "move", "from" => from_path, "path" => to_path}) do
    pointer_from = parse_pointer(from_path)
    with {:ok, value} <- get_at(doc, pointer_from),
         {:ok, without} <- delete_at(doc, pointer_from) do
      set_at(without, parse_pointer(to_path), value)
    else
      :error -> {:error, "move source not found: #{from_path}"}
      err -> err
    end
  end

  defp apply_op(doc, %{"op" => "copy", "from" => from_path, "path" => to_path}) do
    case get_at(doc, parse_pointer(from_path)) do
      {:ok, value} -> set_at(doc, parse_pointer(to_path), value)
      :error -> {:error, "copy source not found: #{from_path}"}
    end
  end

  defp apply_op(_doc, %{"op" => op}), do: {:error, "unsupported operation: #{op}"}

  defp get_at(doc, []), do: {:ok, doc}
  defp get_at(doc, [key | rest]) when is_map(doc) do
    case Map.get(doc, key, Map.get(doc, maybe_to_atom(key))) do
      nil -> :error
      nested -> get_at(nested, rest)
    end
  end
  defp get_at(_, _), do: :error

  defp set_at(_doc, [], value), do: {:ok, value}
  defp set_at(doc, [key | rest], value) when is_map(doc) do
    actual_key = if Map.has_key?(doc, key), do: key, else: maybe_to_atom(key)
    case set_at(Map.get(doc, actual_key, %{}), rest, value) do
      {:ok, nested} -> {:ok, Map.put(doc, actual_key, nested)}
      err -> err
    end
  end
  defp set_at(_, _, _), do: {:error, "cannot set value at non-map node"}

  defp delete_at(doc, [key]) when is_map(doc) do
    actual_key = if Map.has_key?(doc, key), do: key, else: maybe_to_atom(key)
    {:ok, Map.delete(doc, actual_key)}
  end
  defp delete_at(doc, [key | rest]) when is_map(doc) do
    actual_key = if Map.has_key?(doc, key), do: key, else: maybe_to_atom(key)
    case delete_at(Map.get(doc, actual_key, %{}), rest) do
      {:ok, nested} -> {:ok, Map.put(doc, actual_key, nested)}
      err -> err
    end
  end
  defp delete_at(_, _), do: {:error, "path not found"}

  defp maybe_to_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
```

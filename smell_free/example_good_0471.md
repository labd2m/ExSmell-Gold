```elixir
defmodule JsonPatch.Operation do
  @moduledoc false

  @type op :: :add | :remove | :replace | :move | :copy | :test

  @type t :: %__MODULE__{
          op: op(),
          path: [String.t()],
          from: [String.t()] | nil,
          value: term()
        }

  defstruct [:op, :path, :from, :value]

  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_operation}
  def from_map(%{"op" => op_str, "path" => path} = raw) do
    with {:ok, op} <- parse_op(op_str),
         {:ok, parsed_path} <- parse_path(path) do
      parsed_from =
        case Map.fetch(raw, "from") do
          {:ok, f} -> parse_path(f)
          :error -> {:ok, nil}
        end

      case parsed_from do
        {:ok, from} ->
          {:ok, %__MODULE__{op: op, path: parsed_path, from: from, value: Map.get(raw, "value")}}

        {:error, _} = err ->
          err
      end
    end
  end

  def from_map(_), do: {:error, :invalid_operation}

  defp parse_op("add"), do: {:ok, :add}
  defp parse_op("remove"), do: {:ok, :remove}
  defp parse_op("replace"), do: {:ok, :replace}
  defp parse_op("move"), do: {:ok, :move}
  defp parse_op("copy"), do: {:ok, :copy}
  defp parse_op("test"), do: {:ok, :test}
  defp parse_op(_), do: {:error, :invalid_operation}

  defp parse_path("/" <> rest), do: {:ok, String.split(rest, "/")}
  defp parse_path(""), do: {:ok, []}
  defp parse_path(_), do: {:error, :invalid_path}
end

defmodule JsonPatch do
  @moduledoc """
  Applies RFC 6902 JSON Patch operations to Elixir maps.

  Operations are applied atomically: if any single operation fails, the
  original document is returned unchanged. The `test` operation allows
  callers to assert document state before performing mutations.
  """

  alias JsonPatch.Operation

  @type document :: map()
  @type patch :: [map()]

  @spec apply(document(), patch()) :: {:ok, document()} | {:error, term()}
  def apply(document, patch) when is_map(document) and is_list(patch) do
    with {:ok, operations} <- parse_operations(patch) do
      Enum.reduce_while(operations, {:ok, document}, fn op, {:ok, doc} ->
        case apply_op(doc, op) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, reason} -> {:halt, {:error, {op.op, op.path, reason}}}
        end
      end)
    end
  end

  defp parse_operations(raw_ops) do
    Enum.reduce_while(raw_ops, {:ok, []}, fn raw, {:ok, acc} ->
      case Operation.from_map(raw) do
        {:ok, op} -> {:cont, {:ok, [op | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      err -> err
    end
  end

  defp apply_op(doc, %Operation{op: :add, path: path, value: value}) do
    {:ok, put_at(doc, path, value)}
  end

  defp apply_op(doc, %Operation{op: :remove, path: path}) do
    case get_at(doc, path) do
      {:ok, _} -> {:ok, delete_at(doc, path)}
      :error -> {:error, :path_not_found}
    end
  end

  defp apply_op(doc, %Operation{op: :replace, path: path, value: value}) do
    case get_at(doc, path) do
      {:ok, _} -> {:ok, put_at(doc, path, value)}
      :error -> {:error, :path_not_found}
    end
  end

  defp apply_op(doc, %Operation{op: :test, path: path, value: expected}) do
    case get_at(doc, path) do
      {:ok, ^expected} -> {:ok, doc}
      {:ok, _other} -> {:error, :test_failed}
      :error -> {:error, :path_not_found}
    end
  end

  defp apply_op(doc, %Operation{op: :copy, path: path, from: from}) do
    case get_at(doc, from) do
      {:ok, value} -> {:ok, put_at(doc, path, value)}
      :error -> {:error, :from_path_not_found}
    end
  end

  defp apply_op(doc, %Operation{op: :move, path: path, from: from}) do
    case get_at(doc, from) do
      {:ok, value} -> {:ok, doc |> delete_at(from) |> put_at(path, value)}
      :error -> {:error, :from_path_not_found}
    end
  end

  defp get_at(doc, []), do: {:ok, doc}
  defp get_at(doc, [key | rest]) when is_map(doc) do
    case Map.fetch(doc, key) do
      {:ok, child} -> get_at(child, rest)
      :error -> :error
    end
  end
  defp get_at(_, _), do: :error

  defp put_at(_doc, [], value), do: value
  defp put_at(doc, [key | rest], value) when is_map(doc) do
    Map.put(doc, key, put_at(Map.get(doc, key, %{}), rest, value))
  end

  defp delete_at(doc, [key]), do: Map.delete(doc, key)
  defp delete_at(doc, [key | rest]) when is_map(doc) do
    Map.update(doc, key, %{}, &delete_at(&1, rest))
  end
end
```

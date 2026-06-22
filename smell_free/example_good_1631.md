```elixir
defmodule Streaming.NdjsonEncoder do
  @moduledoc """
  Encodes an Ecto query or enumerable as a streaming NDJSON response
  compatible with Plug's chunk-based transfer. Each record is encoded
  independently so memory usage is bounded regardless of result size.
  """

  import Plug.Conn

  alias Streaming.RowTransformer

  @type encoder_opts :: [
          transformer: (map() -> map()) | nil,
          chunk_size: pos_integer(),
          on_error: :skip | :halt
        ]

  @spec stream_query(Plug.Conn.t(), Ecto.Query.t(), module(), encoder_opts()) :: Plug.Conn.t()
  def stream_query(conn, query, repo, opts \\ []) do
    transformer = Keyword.get(opts, :transformer)
    chunk_size = Keyword.get(opts, :chunk_size, 500)
    on_error = Keyword.get(opts, :on_error, :skip)

    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

    query
    |> repo.stream(max_rows: chunk_size)
    |> Stream.map(&apply_transformer(&1, transformer))
    |> Enum.reduce_while(conn, fn row, acc_conn ->
      case encode_row(row) do
        {:ok, line} ->
          case chunk(acc_conn, line <> "\n") do
            {:ok, updated} -> {:cont, updated}
            {:error, _} -> {:halt, acc_conn}
          end

        {:error, _reason} ->
          case on_error do
            :skip -> {:cont, acc_conn}
            :halt -> {:halt, acc_conn}
          end
      end
    end)
  end

  @spec stream_enumerable(Plug.Conn.t(), Enumerable.t(), encoder_opts()) :: Plug.Conn.t()
  def stream_enumerable(conn, enumerable, opts \\ []) do
    transformer = Keyword.get(opts, :transformer)
    on_error = Keyword.get(opts, :on_error, :skip)

    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

    Enum.reduce_while(enumerable, conn, fn item, acc_conn ->
      row = apply_transformer(item, transformer)

      case encode_row(row) do
        {:ok, line} ->
          case chunk(acc_conn, line <> "\n") do
            {:ok, updated} -> {:cont, updated}
            {:error, _} -> {:halt, acc_conn}
          end

        {:error, _} ->
          case on_error do
            :skip -> {:cont, acc_conn}
            :halt -> {:halt, acc_conn}
          end
      end
    end)
  end

  @spec encode_batch([map()]) :: {:ok, binary()} | {:error, [%{index: non_neg_integer(), reason: term()}]}
  def encode_batch(records) when is_list(records) do
    {lines, errors} =
      records
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {record, idx}, {acc_lines, acc_errors} ->
        case encode_row(record) do
          {:ok, line} -> {[line | acc_lines], acc_errors}
          {:error, reason} -> {acc_lines, [%{index: idx, reason: reason} | acc_errors]}
        end
      end)

    case errors do
      [] -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @spec encode_row(map()) :: {:ok, String.t()} | {:error, term()}
  defp encode_row(row) do
    case Jason.encode(row) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec apply_transformer(map(), (map() -> map()) | nil) :: map()
  defp apply_transformer(row, nil), do: row
  defp apply_transformer(row, transformer) when is_function(transformer, 1), do: transformer.(row)
end
```

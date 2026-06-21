```elixir
defmodule AppWeb.Plugs.NdjsonStream do
  @moduledoc """
  A Plug helper for sending large result sets as NDJSON (newline-delimited JSON)
  chunked HTTP responses.

  Each record is serialized independently, enabling the client to process
  records as they arrive without waiting for the complete dataset. The
  stream is backed by `Repo.stream/2` to avoid loading all rows into memory.
  """

  import Plug.Conn

  alias Platform.Repo

  @content_type "application/x-ndjson"
  @chunk_size 100

  @doc """
  Streams `queryable` results to the connection as NDJSON.

  Each row is passed through `encoder_fn` before serialization. The
  response is sent with chunked transfer encoding and the connection
  is halted after the stream completes.
  """
  @spec stream_query(Plug.Conn.t(), Ecto.Queryable.t(), (struct() -> map()), keyword()) ::
          Plug.Conn.t()
  def stream_query(conn, queryable, encoder_fn, opts \\ [])
      when is_function(encoder_fn, 1) do
    chunk_size = Keyword.get(opts, :chunk_size, @chunk_size)

    conn =
      conn
      |> put_resp_content_type(@content_type)
      |> put_resp_header("transfer-encoding", "chunked")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_chunked(200)

    Repo.transaction(fn ->
      queryable
      |> Repo.stream(max_rows: chunk_size)
      |> Stream.map(encoder_fn)
      |> Stream.map(&Jason.encode!/1)
      |> Stream.intersperse("\n")
      |> Stream.chunk_every(chunk_size)
      |> Enum.each(fn batch ->
        chunk_data = Enum.join(batch) <> "\n"
        case chunk(conn, chunk_data) do
          {:ok, _conn} -> :ok
          {:error, :closed} -> throw(:client_disconnected)
        end
      end)
    end, timeout: :infinity)

    halt(conn)
  end

  @doc """
  Streams a pre-materialized list of maps as NDJSON.
  Use for smaller in-memory result sets.
  """
  @spec stream_list(Plug.Conn.t(), [map()], keyword()) :: Plug.Conn.t()
  def stream_list(conn, records, opts \\ []) when is_list(records) do
    batch_size = Keyword.get(opts, :batch_size, 200)

    conn =
      conn
      |> put_resp_content_type(@content_type)
      |> send_chunked(200)

    records
    |> Stream.map(&Jason.encode!/1)
    |> Stream.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      payload = Enum.join(batch, "\n") <> "\n"
      chunk(conn, payload)
    end)

    halt(conn)
  end
end

defmodule AppWeb.ExportController do
  @moduledoc """
  Controller that streams large data exports using NDJSON chunked responses.
  """

  use AppWeb, :controller

  import AppWeb.Plugs.NdjsonStream, only: [stream_query: 4]
  import Ecto.Query, only: [from: 2]
  alias Platform.{Repo, Event}

  @doc "Streams all events for an account as NDJSON."
  def events(conn, %{"account_id" => account_id}) do
    query = from(e in Event, where: e.account_id == ^account_id, order_by: [asc: e.id])
    stream_query(conn, query, &event_to_map/1)
  end

  defp event_to_map(event) do
    %{
      id: event.id,
      type: event.type,
      payload: event.payload,
      occurred_at: DateTime.to_iso8601(event.occurred_at)
    }
  end
end
```

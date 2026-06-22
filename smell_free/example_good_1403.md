**File:** `example_good_1403.md`

```elixir
defmodule Idempotency.StoredResponse do
  @moduledoc "Schema for a cached idempotent response record."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          idempotency_key: String.t(),
          request_fingerprint: String.t(),
          status_code: pos_integer(),
          body: map(),
          created_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "idempotent_responses" do
    field :idempotency_key, :string
    field :request_fingerprint, :string
    field :status_code, :integer
    field :body, :map
    field :created_at, :utc_datetime_usec
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:idempotency_key, :request_fingerprint, :status_code, :body, :created_at])
    |> validate_required([:idempotency_key, :request_fingerprint, :status_code, :body, :created_at])
    |> validate_number(:status_code, greater_than_or_equal_to: 100, less_than: 600)
    |> unique_constraint(:idempotency_key)
  end
end

defmodule Idempotency.Store do
  @moduledoc """
  Reads and writes idempotent response records backed by Postgres.
  Handles concurrent races via unique constraint on idempotency_key.
  """

  alias Idempotency.StoredResponse
  alias MyApp.Repo

  @type lookup_result :: {:ok, StoredResponse.t()} | {:error, :not_found}
  @type store_result :: {:ok, StoredResponse.t()} | {:error, :conflict} | {:error, Ecto.Changeset.t()}

  @spec lookup(String.t()) :: lookup_result()
  def lookup(key) when is_binary(key) do
    case Repo.get_by(StoredResponse, idempotency_key: key) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @spec store(String.t(), String.t(), pos_integer(), map()) :: store_result()
  def store(key, fingerprint, status_code, body) do
    attrs = %{
      idempotency_key: key,
      request_fingerprint: fingerprint,
      status_code: status_code,
      body: body,
      created_at: DateTime.utc_now()
    }

    case %StoredResponse{} |> StoredResponse.changeset(attrs) |> Repo.insert() do
      {:ok, _} = ok -> ok
      {:error, %Ecto.Changeset{errors: [{:idempotency_key, _} | _]}} -> {:error, :conflict}
      {:error, _} = err -> err
    end
  end
end

defmodule Idempotency.Plug do
  @moduledoc """
  A Plug that intercepts requests carrying an Idempotency-Key header.
  On first request, the response is stored. On replay, the stored
  response is returned immediately without re-executing the handler.
  Mismatched request fingerprints are rejected with 422.
  """

  import Plug.Conn

  alias Idempotency.Store

  @header "idempotency-key"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case get_req_header(conn, @header) do
      [] -> conn
      [key | _] -> handle_idempotent_request(conn, key)
    end
  end

  defp handle_idempotent_request(conn, key) do
    fingerprint = compute_fingerprint(conn)

    case Store.lookup(key) do
      {:error, :not_found} ->
        conn
        |> assign(:idempotency_key, key)
        |> assign(:idempotency_fingerprint, fingerprint)
        |> register_before_send(&maybe_store_response(&1, key, fingerprint))

      {:ok, stored} ->
        replay_stored_response(conn, stored, fingerprint)
    end
  end

  defp replay_stored_response(conn, stored, fingerprint) do
    if stored.request_fingerprint == fingerprint do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("x-idempotency-replayed", "true")
      |> send_resp(stored.status_code, Jason.encode!(stored.body))
      |> halt()
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(422, Jason.encode!(%{error: "idempotency_key_reuse_with_different_request"}))
      |> halt()
    end
  end

  defp maybe_store_response(conn, key, fingerprint) do
    with {:ok, body_str} <- fetch_resp_body(conn),
         {:ok, body_map} <- Jason.decode(body_str) do
      Store.store(key, fingerprint, conn.status, body_map)
    end

    conn
  end

  defp fetch_resp_body(%Plug.Conn{resp_body: body}) when is_binary(body), do: {:ok, body}
  defp fetch_resp_body(_), do: {:error, :no_body}

  defp compute_fingerprint(conn) do
    parts = [conn.method, conn.request_path, inspect(conn.body_params)]
    :crypto.hash(:sha256, Enum.join(parts, ":")) |> Base.url_encode64(padding: false)
  end
end
```

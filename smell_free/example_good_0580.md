```elixir
defmodule AppWeb.ErrorResponse do
  @moduledoc """
  Builds consistent, structured JSON error responses across all controllers
  and plugs.

  All errors share a common envelope with a `code`, `message`, and optional
  `details` field. Ecto changeset errors are translated to field-level detail
  maps. HTTP status codes are derived from the error category.
  """

  import Plug.Conn

  @type error_code :: atom()
  @type detail :: map() | [map()]
  @type envelope :: %{code: String.t(), message: String.t(), details: detail() | nil}

  @status_map %{
    not_found: 404,
    unauthorized: 401,
    forbidden: 403,
    unprocessable: 422,
    conflict: 409,
    bad_request: 400,
    rate_limited: 429,
    service_unavailable: 503,
    internal_error: 500
  }

  @doc "Sends a JSON error response and halts the connection."
  @spec send_error(Plug.Conn.t(), error_code(), String.t(), detail() | nil) :: Plug.Conn.t()
  def send_error(conn, code, message, details \\ nil) do
    status = Map.get(@status_map, code, 500)
    body = build_envelope(code, message, details)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  @doc "Sends a 422 error response derived from an Ecto changeset."
  @spec send_changeset_error(Plug.Conn.t(), Ecto.Changeset.t()) :: Plug.Conn.t()
  def send_changeset_error(conn, %Ecto.Changeset{} = changeset) do
    details = changeset_to_details(changeset)
    send_error(conn, :unprocessable, "Validation failed", details)
  end

  @doc "Builds an error envelope map without sending it."
  @spec build_envelope(error_code(), String.t(), detail() | nil) :: envelope()
  def build_envelope(code, message, details \\ nil) do
    base = %{code: Atom.to_string(code), message: message}
    if details, do: Map.put(base, :details, details), else: base
  end

  @doc "Returns the HTTP status integer for the given error code."
  @spec http_status(error_code()) :: pos_integer()
  def http_status(code), do: Map.get(@status_map, code, 500)

  @doc "Converts an Ecto changeset into a list of field-level error maps."
  @spec changeset_to_details(Ecto.Changeset.t()) :: [map()]
  def changeset_to_details(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message ->
        %{field: Atom.to_string(field), message: message}
      end)
    end)
  end

  @doc """
  Wraps a controller action result, automatically sending the appropriate
  error response on `{:error, reason}`.
  """
  @spec handle_result(Plug.Conn.t(), {:ok, term()} | {:error, term()}, (Plug.Conn.t(), term() -> Plug.Conn.t())) :: Plug.Conn.t()
  def handle_result(conn, {:ok, value}, success_fn), do: success_fn.(conn, value)

  def handle_result(conn, {:error, %Ecto.Changeset{} = cs}, _success_fn) do
    send_changeset_error(conn, cs)
  end

  def handle_result(conn, {:error, :not_found}, _success_fn) do
    send_error(conn, :not_found, "Resource not found")
  end

  def handle_result(conn, {:error, :unauthorized}, _success_fn) do
    send_error(conn, :unauthorized, "Authentication required")
  end

  def handle_result(conn, {:error, :forbidden}, _success_fn) do
    send_error(conn, :forbidden, "Access denied")
  end

  def handle_result(conn, {:error, reason}, _success_fn) do
    require Logger
    Logger.error("Unhandled error in controller", reason: inspect(reason))
    send_error(conn, :internal_error, "An unexpected error occurred")
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
```

```elixir
defmodule MyAppWeb.Plug.ErrorHandler do
  @moduledoc """
  A Plug-compatible error handler that converts any unhandled exception or
  Plug error into a structured JSON response. Responses follow a consistent
  schema across all error classes so API clients can parse errors uniformly
  without inspecting HTTP status codes alone. Internal error details are
  included in development and stripped in production to prevent information
  leakage.
  """

  @behaviour Plug.ErrorHandler

  import Plug.Conn

  require Logger

  @type error_response :: %{
          error: binary(),
          message: binary(),
          request_id: binary() | nil,
          details: map() | nil
        }

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    {status, error_code, message} = classify_error(kind, reason)

    log_error(conn, kind, reason, stack, status)

    body =
      %{
        error: error_code,
        message: message,
        request_id: conn.assigns[:trace_id]
      }
      |> maybe_add_details(reason)
      |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # ---------------------------------------------------------------------------
  # Public helpers for use in controllers
  # ---------------------------------------------------------------------------

  @doc """
  Sends a structured JSON error response. Intended for use inside Phoenix
  controllers where `conn` is available and the error is known at call time.
  """
  @spec send_error(Plug.Conn.t(), non_neg_integer(), binary(), binary(), map()) :: Plug.Conn.t()
  def send_error(conn, status, error_code, message, details \\ %{}) do
    body =
      %{
        error: error_code,
        message: message,
        request_id: conn.assigns[:trace_id],
        details: if(map_size(details) > 0, do: details, else: nil)
      }
      |> Jason.encode!()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  @doc """
  Converts an Ecto changeset into a structured `422` JSON response with
  per-field validation errors.
  """
  @spec send_changeset_error(Plug.Conn.t(), Ecto.Changeset.t()) :: Plug.Conn.t()
  def send_changeset_error(conn, %Ecto.Changeset{} = changeset) do
    field_errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    send_error(conn, 422, "validation_failed", "Request validation failed",
      %{field_errors: field_errors})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp classify_error(:error, %Plug.BadRequestError{}),
    do: {400, "bad_request", "The request could not be understood"}

  defp classify_error(:error, %MyApp.Auth.UnauthorizedError{}),
    do: {401, "unauthorized", "Authentication required"}

  defp classify_error(:error, %MyApp.Auth.ForbiddenError{}),
    do: {403, "forbidden", "You do not have permission to perform this action"}

  defp classify_error(:error, %Ecto.NoResultsError{}),
    do: {404, "not_found", "The requested resource was not found"}

  defp classify_error(:error, %Plug.Conn.InvalidQueryError{}),
    do: {400, "invalid_query", "The query string could not be parsed"}

  defp classify_error(:error, %Ecto.StaleEntryError{}),
    do: {409, "conflict", "The resource was modified by another process"}

  defp classify_error(_kind, _reason),
    do: {500, "internal_server_error", "An unexpected error occurred"}

  defp maybe_add_details(body, reason) do
    if Application.get_env(:my_app, :env) == :dev do
      Map.put(body, :debug, %{
        exception: inspect(reason),
        type: reason.__struct__ |> to_string()
      })
    else
      body
    end
  end

  defp log_error(conn, _kind, _reason, _stack, status) when status < 500 do
    Logger.info("Client error",
      status: status,
      path: conn.request_path,
      request_id: conn.assigns[:trace_id]
    )
  end

  defp log_error(conn, kind, reason, stack, status) do
    Logger.error("Server error",
      status: status,
      kind: kind,
      reason: inspect(reason),
      path: conn.request_path,
      request_id: conn.assigns[:trace_id],
      stacktrace: Exception.format_stacktrace(stack)
    )
  end
end
```

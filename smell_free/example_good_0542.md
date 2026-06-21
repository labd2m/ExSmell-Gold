```elixir
defmodule Ops.MaintenanceWindow do
  @moduledoc """
  Enforces scheduled maintenance windows as a Plug. When a maintenance
  window is active, non-exempt requests receive a 503 response with a
  `Retry-After` header. Window schedules are loaded from application
  configuration and re-evaluated on each request so they can be updated
  at runtime. Health check and status endpoints are exempt by default.
  """

  @behaviour Plug

  import Plug.Conn

  @type window :: %{
          label: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          message: String.t()
        }

  @exempt_paths ~w(/health /status /ping)

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, opts) do
    exempt_paths = Keyword.get(opts, :exempt_paths, @exempt_paths)

    if conn.request_path in exempt_paths do
      conn
    else
      case active_window() do
        nil ->
          conn

        window ->
          retry_after = DateTime.diff(window.ends_at, DateTime.utc_now(), :second) |> max(0)

          conn
          |> put_resp_header("retry-after", Integer.to_string(retry_after))
          |> put_resp_header("content-type", "application/json")
          |> send_resp(503, encode_maintenance_body(window))
          |> halt()
      end
    end
  end

  @doc "Returns the currently active maintenance window, if any."
  @spec active_window() :: window() | nil
  def active_window do
    now = DateTime.utc_now()

    load_windows()
    |> Enum.find(fn window ->
      DateTime.compare(window.starts_at, now) != :gt and
        DateTime.compare(window.ends_at, now) == :gt
    end)
  end

  @doc "Returns true when a maintenance window is currently in effect."
  @spec in_maintenance?() :: boolean()
  def in_maintenance?, do: not is_nil(active_window())

  @doc """
  Returns the next scheduled window after `reference_dt`, or `nil` when
  none is scheduled.
  """
  @spec next_window(DateTime.t()) :: window() | nil
  def next_window(reference_dt \ DateTime.utc_now()) do
    load_windows()
    |> Enum.filter(fn w -> DateTime.compare(w.starts_at, reference_dt) == :gt end)
    |> Enum.min_by(fn w -> DateTime.to_unix(w.starts_at) end, fn -> nil end)
  end

  defp load_windows do
    :my_app
    |> Application.get_env(:maintenance_windows, [])
    |> Enum.map(&parse_window/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_window(%{starts_at: starts_at, ends_at: ends_at} = raw)
       when is_binary(starts_at) and is_binary(ends_at) do
    with {:ok, sa, _} <- DateTime.from_iso8601(starts_at),
         {:ok, ea, _} <- DateTime.from_iso8601(ends_at) do
      %{
        label: Map.get(raw, :label, "Scheduled Maintenance"),
        starts_at: sa,
        ends_at: ea,
        message: Map.get(raw, :message, "We are currently performing scheduled maintenance.")
      }
    else
      _ -> nil
    end
  end

  defp parse_window(_), do: nil

  defp encode_maintenance_body(%{label: label, message: message, ends_at: ends_at}) do
    Jason.encode!(%{
      error: "service_unavailable",
      reason: label,
      message: message,
      available_after: DateTime.to_iso8601(ends_at)
    })
  end
end
```

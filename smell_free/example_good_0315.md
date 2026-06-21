```elixir
defmodule Gateway.Plugs.ContentNegotiation do
  @moduledoc """
  Selects a response content type by negotiating with the request's
  Accept header.

  The plug resolves the client's preferred media type against the handler's
  declared list of producible types using q-factor weighted matching.
  Requests with no matching Accept type are halted with HTTP 406 before
  reaching the handler. The resolved type is stored in the conn assigns so
  downstream handlers can format the response body correctly.
  """

  @behaviour Plug

  alias Plug.Conn

  @type opts :: %{produces: [String.t()]}

  @impl Plug
  def init(opts) do
    produces = Keyword.fetch!(opts, :produces)
    %{produces: produces}
  end

  @impl Plug
  def call(%Conn{} = conn, %{produces: produces}) do
    accept_header = conn |> Conn.get_req_header("accept") |> List.first("*/*")

    case negotiate(accept_header, produces) do
      {:ok, content_type} ->
        Conn.assign(conn, :response_content_type, content_type)

      {:error, :not_acceptable} ->
        body = Jason.encode!(%{error: "None of the requested media types are producible"})

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(406, body)
        |> Conn.halt()
    end
  end

  @spec negotiate(String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, :not_acceptable}
  def negotiate(accept_header, producible_types)
      when is_binary(accept_header) and is_list(producible_types) do
    accepted = parse_accept(accept_header)

    result =
      Enum.find_value(accepted, fn {media_range, _q} ->
        Enum.find(producible_types, &matches?(media_range, &1))
      end)

    case result do
      nil -> {:error, :not_acceptable}
      type -> {:ok, type}
    end
  end

  defp parse_accept(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_media_range/1)
    |> Enum.sort_by(fn {_type, q} -> -q end)
  end

  defp parse_media_range(segment) do
    {media_range, params_str} =
      case String.split(String.trim(segment), ";", parts: 2) do
        [range, params] -> {String.trim(range), params}
        [range] -> {String.trim(range), ""}
      end

    q =
      case Regex.run(~r/q=([\d.]+)/, params_str) do
        [_, q_str] -> String.to_float(q_str)
        nil -> 1.0
      end

    {media_range, q}
  end

  defp matches?("*/*", _type), do: true

  defp matches?(media_range, content_type) do
    case String.split(media_range, "/") do
      [type, "*"] -> String.starts_with?(content_type, "#{type}/")
      _ -> media_range == content_type
    end
  end
end
```

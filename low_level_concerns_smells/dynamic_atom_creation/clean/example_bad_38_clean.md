```elixir
defmodule Gateway.UpstreamProxy do
  @moduledoc """
  Forwards requests to upstream microservices, normalises their responses,
  and propagates relevant headers back to the original caller.
  """

  require Logger

  alias Gateway.{RequestContext, CircuitBreaker, MetricsCollector, HeaderFilter}

  @forwarded_headers ~w(
    content-type
    cache-control
    etag
    last-modified
    x-request-id
    x-ratelimit-limit
    x-ratelimit-remaining
    x-correlation-id
  )

  @timeout_ms 10_000
  @max_body_bytes 8 * 1024 * 1024

  @spec forward(RequestContext.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def forward(%RequestContext{} = ctx, upstream_url) do
    Logger.debug("Forwarding request", upstream: upstream_url, request_id: ctx.request_id)

    with :ok <- CircuitBreaker.check(upstream_url),
         {:ok, response} <- execute_request(ctx, upstream_url),
         {:ok, normalized} <- normalize_response(response) do
      MetricsCollector.record("gateway", "upstream_request", 1)
      {:ok, normalized}
    else
      {:error, :circuit_open} ->
        Logger.warning("Circuit open for upstream", url: upstream_url)
        {:error, :upstream_unavailable}

      {:error, reason} = err ->
        Logger.error("Upstream request failed",
          url: upstream_url,
          reason: inspect(reason)
        )
        MetricsCollector.record("gateway", "upstream_error", 1)
        err
    end
  end

  defp execute_request(ctx, url) do
    headers = build_forwarded_headers(ctx)

    case HTTPoison.request(ctx.method, url, ctx.body, headers,
           timeout: @timeout_ms,
           recv_timeout: @timeout_ms,
           max_body_length: @max_body_bytes
         ) do
      {:ok, %HTTPoison.Response{} = resp} -> {:ok, resp}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, {:http_error, reason}}
    end
  end

  defp build_forwarded_headers(ctx) do
    ctx.headers
    |> Enum.filter(fn {name, _} -> name in @forwarded_headers end)
    |> Enum.into([{"x-forwarded-for", ctx.remote_ip}])
  end

  defp normalize_response(%HTTPoison.Response{headers: raw_headers, body: body, status_code: status}) do
    with {:ok, parsed_body} <- parse_body(body),
         {:ok, normalized_headers} <- normalize_headers(raw_headers) do
      {:ok,
       %{
         status: status,
         body: parsed_body,
         headers: normalized_headers
       }}
    end
  end

  defp normalize_headers(headers) do
    filtered =
      headers
      |> Enum.filter(fn {name, _} -> String.downcase(name) in @forwarded_headers end)

    normalized =
      Enum.into(filtered, %{}, fn {name, value} ->
        {header_to_key(name), value}
      end)

    {:ok, normalized}
  end

  defp header_to_key(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp parse_body(""), do: {:ok, nil}
  defp parse_body(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:ok, body}
    end
  end
end
```

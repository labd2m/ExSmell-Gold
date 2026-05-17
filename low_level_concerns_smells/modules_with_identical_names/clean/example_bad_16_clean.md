```elixir
# ── file: lib/api/rate_limiter.ex ────────────────────────────────────────────

defmodule API.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter for API endpoints. Evaluated on every inbound
  HTTP request by the plug pipeline before routing to controllers.
  """

  alias API.{RateLimitStore, QuotaConfig, MetricsCollector}

  @default_window_seconds 60
  @default_max_requests 100
  @burst_multiplier 1.5

  @type limit_result ::
          {:ok, %{remaining: non_neg_integer(), reset_at: DateTime.t()}}
          | {:error, :rate_limited, %{retry_after: non_neg_integer()}}

  @spec check(String.t(), String.t()) :: limit_result()
  def check(client_id, endpoint) do
    quota = QuotaConfig.get(client_id, endpoint) || default_quota()

    window_key = window_key(client_id, endpoint)
    now = System.system_time(:second)
    window_start = now - rem(now, quota.window_seconds)
    reset_at = DateTime.from_unix!(window_start + quota.window_seconds)

    case RateLimitStore.increment(window_key, window_start + quota.window_seconds) do
      {:ok, count} when count <= quota.max_requests ->
        remaining = quota.max_requests - count
        MetricsCollector.record_api_request(client_id, endpoint, :allowed)
        {:ok, %{remaining: remaining, reset_at: reset_at}}

      {:ok, count} when count <= trunc(quota.max_requests * @burst_multiplier) ->
        MetricsCollector.record_api_request(client_id, endpoint, :burst)
        {:ok, %{remaining: 0, reset_at: reset_at}}

      {:ok, _} ->
        retry_after = reset_at |> DateTime.diff(DateTime.utc_now(), :second) |> max(1)
        MetricsCollector.record_api_request(client_id, endpoint, :throttled)
        {:error, :rate_limited, %{retry_after: retry_after}}
    end
  end

  @spec peek(String.t(), String.t()) :: %{count: non_neg_integer(), quota: map()}
  def peek(client_id, endpoint) do
    quota = QuotaConfig.get(client_id, endpoint) || default_quota()
    window_key = window_key(client_id, endpoint)

    count = RateLimitStore.get(window_key) || 0
    %{count: count, quota: quota}
  end

  @spec reset(String.t(), String.t()) :: :ok
  def reset(client_id, endpoint) do
    window_key = window_key(client_id, endpoint)
    RateLimitStore.delete(window_key)
    :ok
  end

  defp window_key(client_id, endpoint) do
    now = System.system_time(:second)
    bucket = div(now, @default_window_seconds)
    "rl:#{client_id}:#{endpoint}:#{bucket}"
  end

  defp default_quota do
    %{
      max_requests: @default_max_requests,
      window_seconds: @default_window_seconds
    }
  end
end


# ── file: lib/api/rate_limiter_config.ex ─────────────────────────────────────

defmodule API.RateLimiter do
  @moduledoc """
  Admin interface for managing API rate limit quotas per client and endpoint.
  Used by the developer portal and internal tooling to override defaults.
  """

  alias API.{QuotaConfig, AuditLog}

  @max_requests_ceiling 10_000
  @min_window_seconds 10
  @max_window_seconds 3_600

  @spec configure(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def configure(client_id, quota_attrs) do
    with {:ok, validated} <- validate_quota(quota_attrs) do
      endpoint = Map.get(quota_attrs, :endpoint, "*")

      quota = %{
        client_id: client_id,
        endpoint: endpoint,
        max_requests: validated.max_requests,
        window_seconds: validated.window_seconds,
        updated_at: DateTime.utc_now()
      }

      QuotaConfig.set(client_id, endpoint, quota)

      AuditLog.write(:rate_limit_configured, %{
        client_id: client_id,
        endpoint: endpoint,
        max_requests: quota.max_requests,
        window_seconds: quota.window_seconds
      })

      {:ok, quota}
    end
  end

  @spec remove_override(String.t(), String.t()) :: :ok
  def remove_override(client_id, endpoint \\ "*") do
    QuotaConfig.delete(client_id, endpoint)
    AuditLog.write(:rate_limit_override_removed, %{client_id: client_id, endpoint: endpoint})
    :ok
  end

  @spec list_overrides(String.t()) :: [map()]
  def list_overrides(client_id) do
    QuotaConfig.list_for_client(client_id)
  end

  defp validate_quota(attrs) do
    max_requests = attrs[:max_requests]
    window_seconds = attrs[:window_seconds]

    cond do
      is_nil(max_requests) or not is_integer(max_requests) ->
        {:error, %{max_requests: "must be an integer"}}

      max_requests < 1 or max_requests > @max_requests_ceiling ->
        {:error, %{max_requests: "must be between 1 and #{@max_requests_ceiling}"}}

      is_nil(window_seconds) or not is_integer(window_seconds) ->
        {:error, %{window_seconds: "must be an integer"}}

      window_seconds < @min_window_seconds or window_seconds > @max_window_seconds ->
        {:error, %{window_seconds: "must be between #{@min_window_seconds} and #{@max_window_seconds}"}}

      true ->
        {:ok, %{max_requests: max_requests, window_seconds: window_seconds}}
    end
  end
end
```

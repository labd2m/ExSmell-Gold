```elixir
defmodule Auth.RiskAssessor do
  @moduledoc """
  Evaluates the risk level of an incoming authentication event.
  Produces a risk score and recommended action (allow / challenge / deny)
  that the login pipeline consults before granting a session token.
  """

  alias Auth.{UserCredential, GeoLocation, DeviceFingerprint}
  alias Auth.RiskAssessor.{Score, Action}

  @low_risk_threshold    30
  @medium_risk_threshold 65
  @max_failed_attempts   5
  @ip_history_window_days 90

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Returns a `%Score{}` containing a numeric risk score (0–100) and
  a recommended `%Action{}` for the given user and request context.
  """
  @spec assess(String.t(), map()) :: Score.t()
  def assess(user_id, request_context) do
    score_value = compute_login_risk(user_id, request_context)

    action =
      cond do
        score_value >= @medium_risk_threshold -> Action.deny()
        score_value >= @low_risk_threshold    -> Action.challenge(:mfa)
        true                                  -> Action.allow()
      end

    %Score{value: score_value, action: action, assessed_at: DateTime.utc_now()}
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp compute_login_risk(user_id, %{ip_address: ip, device_id: device_id}) do
    credential       = UserCredential.get_by_user!(user_id)
    failed_attempts  = UserCredential.recent_failed_attempts(credential, hours: 24)
    last_login       = UserCredential.last_successful_login(credential)
    known_ips        = UserCredential.known_ip_addresses(credential, days: @ip_history_window_days)
    mfa_on           = UserCredential.mfa_enabled?(credential)

    score = 0

    score =
      if credential.locked_until && DateTime.compare(credential.locked_until, DateTime.utc_now()) == :gt do
        score + 40
      else
        score
      end

    score = score + min(failed_attempts * 8, 32)

    score =
      if ip not in known_ips do
        geo = GeoLocation.lookup(ip)
        if GeoLocation.high_risk_country?(geo), do: score + 20, else: score + 8
      else
        score
      end

    score =
      case last_login do
        nil -> score + 10
        dt  ->
          days_since = DateTime.diff(DateTime.utc_now(), dt, :second) / 86_400
          if days_since > 60, do: score + 6, else: score
      end

    score =
      if DeviceFingerprint.unknown?(device_id, credential.id), do: score + 10, else: score

    score = if mfa_on, do: max(score - 15, 0), else: score

    score =
      Enum.reduce(credential.risk_flags, score, fn flag, acc ->
        acc + risk_flag_weight(flag)
      end)

    min(score, 100)
  end

  defp risk_flag_weight(:credential_stuffing_suspected), do: 20
  defp risk_flag_weight(:password_recently_reset),       do: 5
  defp risk_flag_weight(:account_sharing_detected),      do: 15
  defp risk_flag_weight(:tor_exit_node_history),         do: 18
  defp risk_flag_weight(_unknown),                       do: 0
end
```

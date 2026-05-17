```elixir
defmodule Audit.LogParser do
  @moduledoc """
  Parses structured audit log entries emitted by application services into
  queryable audit trail records. Used for compliance reporting, security
  investigations, and anomaly detection.

  Expected log format:
    [2024-03-15T14:22:00.123Z] [INFO] [user_id=usr_42] [action=login_success]
    [resource=session] [ip=192.168.1.10] [request_id=req_abc123]
  """

  require Logger

  @log_pattern ~r/
    \[(?P<timestamp>[^\]]+)\]\s+
    \[(?P<level>[^\]]+)\]\s+
    \[user_id=(?P<user_id>[^\]]+)\]\s+
    \[action=(?P<action>[^\]]+)\]\s+
    \[resource=(?P<resource>[^\]]+)\]\s+
    \[ip=(?P<ip>[^\]]+)\]\s+
    \[request_id=(?P<request_id>[^\]]+)\]
  /x

  @sensitive_actions ~w(login_success login_failure password_reset
                        permission_change data_export admin_access)

  def parse_file(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&parse_entry/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end

  def parse_entry(line) do
    captures = Regex.named_captures(@log_pattern, line)

    timestamp  = Map.get(captures, "timestamp", "")
    level      = Map.get(captures, "level", "")
    user_id    = Map.get(captures, "user_id", "")
    action     = Map.get(captures, "action", "")
    resource   = Map.get(captures, "resource", "")
    ip         = Map.get(captures, "ip", "")
    request_id = Map.get(captures, "request_id", "")

    %{
      timestamp:  parse_timestamp(timestamp),
      level:      String.downcase(level),
      user_id:    user_id,
      action:     action,
      resource:   resource,
      ip:         ip,
      request_id: request_id,
      sensitive:  action in @sensitive_actions
    }
  rescue
    _ -> nil
  end

  def filter_sensitive(entries) do
    Enum.filter(entries, & &1.sensitive)
  end

  def filter_by_user(entries, user_id) do
    Enum.filter(entries, &(&1.user_id == user_id))
  end

  def filter_by_action(entries, action) do
    Enum.filter(entries, &(&1.action == action))
  end

  def group_by_user(entries) do
    Enum.group_by(entries, & &1.user_id)
  end

  def action_frequency(entries) do
    entries
    |> Enum.group_by(& &1.action)
    |> Enum.map(fn {action, rows} -> {action, length(rows)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  def suspicious_ips(entries, threshold \\ 10) do
    entries
    |> Enum.filter(&(&1.action == "login_failure"))
    |> Enum.group_by(& &1.ip)
    |> Enum.filter(fn {_ip, rows} -> length(rows) >= threshold end)
    |> Enum.map(&elem(&1, 0))
  end

  def compliance_report(entries, from_date, to_date) do
    in_range =
      Enum.filter(entries, fn entry ->
        with %DateTime{} = ts <- entry.timestamp do
          DateTime.compare(ts, from_date) != :lt and
            DateTime.compare(ts, to_date) != :gt
        else
          _ -> false
        end
      end)

    %{
      total_events:     length(in_range),
      sensitive_events: in_range |> filter_sensitive() |> length(),
      unique_users:     in_range |> Enum.map(& &1.user_id) |> Enum.uniq() |> length(),
      period_start:     from_date,
      period_end:       to_date
    }
  end

  defp parse_timestamp(""), do: nil
  defp parse_timestamp(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _            -> nil
    end
  end
end
```

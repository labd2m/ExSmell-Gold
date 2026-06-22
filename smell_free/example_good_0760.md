```elixir
defmodule MyApp.Ops.ConfigDriftDetector do
  @moduledoc """
  Compares the application's live runtime configuration against a
  canonical reference snapshot stored in object storage. When drift is
  detected — keys that are missing, extra, or whose values differ — a
  structured report is produced and broadcast over PubSub for alerting.

  Intended to run on a schedule from an Oban job to catch accidental
  configuration changes between deployments.
  """

  require Logger

  alias MyApp.Storage
  alias MyApp.Infra.SecretManager

  @pubsub MyApp.PubSub
  @topic "ops:config_drift"
  @snapshot_key "ops/config_snapshots/reference.json"

  @type drift_entry :: %{
          key: String.t(),
          kind: :missing | :extra | :changed,
          reference_value: term(),
          live_value: term()
        }

  @type drift_report :: %{
          drifted: boolean(),
          entries: [drift_entry()],
          snapshot_etag: String.t() | nil,
          checked_at: DateTime.t()
        }

  @doc """
  Performs a configuration drift check. Returns `{:ok, report}` or
  `{:error, reason}` when the reference snapshot cannot be loaded.
  """
  @spec check() :: {:ok, drift_report()} | {:error, term()}
  def check do
    with {:ok, {reference, etag}} <- load_reference_snapshot(),
         live <- collect_live_config() do
      entries = compute_drift(reference, live)
      report = build_report(entries, etag)

      if report.drifted do
        Logger.warning("config_drift_detected", entry_count: length(entries))
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_drift_detected, report})
      end

      {:ok, report}
    end
  end

  @doc """
  Saves the current live configuration as the new reference snapshot,
  effectively acknowledging any outstanding drift.
  """
  @spec save_snapshot() :: :ok | {:error, term()}
  def save_snapshot do
    live = collect_live_config()
    content = Jason.encode!(live)

    case Storage.put(@snapshot_key, content, content_type: "application/json") do
      {:ok, _url} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_reference_snapshot() :: {:ok, {map(), String.t() | nil}} | {:error, term()}
  defp load_reference_snapshot do
    case Storage.get(@snapshot_key) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} -> {:ok, {map, nil}}
          {:error, reason} -> {:error, {:invalid_snapshot, reason}}
        end

      {:error, :not_found} ->
        {:error, :no_reference_snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec collect_live_config() :: map()
  defp collect_live_config do
    env = Application.get_all_env(:my_app)

    base =
      Map.new(env, fn {key, value} ->
        {to_string(key), sanitise_value(value)}
      end)

    secret_keys = [:stripe_secret_key, :smtp_password, :aws_secret_access_key]

    Enum.reduce(secret_keys, base, fn key, acc ->
      case SecretManager.get(to_string(key)) do
        {:ok, _value} -> Map.put(acc, to_string(key), "**present**")
        {:error, _} -> acc
      end
    end)
  end

  @spec compute_drift(map(), map()) :: [drift_entry()]
  defp compute_drift(reference, live) do
    missing =
      Enum.flat_map(reference, fn {k, ref_val} ->
        case Map.get(live, k) do
          nil -> [%{key: k, kind: :missing, reference_value: ref_val, live_value: nil}]
          live_val when live_val != ref_val -> [%{key: k, kind: :changed, reference_value: ref_val, live_value: live_val}]
          _ -> []
        end
      end)

    extra =
      Enum.flat_map(live, fn {k, live_val} ->
        if Map.has_key?(reference, k), do: [],
          else: [%{key: k, kind: :extra, reference_value: nil, live_value: live_val}]
      end)

    missing ++ extra
  end

  @spec build_report([drift_entry()], String.t() | nil) :: drift_report()
  defp build_report(entries, etag) do
    %{
      drifted: entries != [],
      entries: entries,
      snapshot_etag: etag,
      checked_at: DateTime.utc_now()
    }
  end

  @spec sanitise_value(term()) :: term()
  defp sanitise_value(value) when is_binary(value), do: value
  defp sanitise_value(value) when is_number(value), do: value
  defp sanitise_value(value) when is_boolean(value), do: value
  defp sanitise_value(nil), do: nil
  defp sanitise_value(_), do: "**complex**"
end
```

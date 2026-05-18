# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Audit.Logger` module, `build_entry/3` macro |
| **Affected function(s)** | `build_entry/3` |
| **Short explanation** | `build_entry/3` builds a plain map from runtime values. All fields are known only at runtime, so there is no compile-time work to do; a regular function is the right tool and would eliminate the `require` burden imposed on every caller. |

```elixir
defmodule Audit.Logger do
  @moduledoc """
  Creates and persists structured audit log entries for security-sensitive
  operations such as login attempts, permission changes, and data exports.
  """

  require Logger

  @log_levels [:info, :warning, :critical]
  @version "1.0"

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `build_entry/3` assembles a map
  # from arguments that are all runtime values (actor_id, action, metadata).
  # No part of this computation benefits from compile-time expansion.
  # A `def` function would be simpler, testable in isolation, and would not
  # require callers to issue a `require Audit.Logger` directive.
  defmacro build_entry(actor_id, action, metadata) do
    quote do
      %{
        id: Ecto.UUID.generate(),
        actor_id: unquote(actor_id),
        action: unquote(action),
        metadata: unquote(metadata),
        occurred_at: DateTime.utc_now(),
        version: unquote(@version),
        level: :info
      }
    end
  end
  # VALIDATION: SMELL END

  def log(actor_id, action, metadata \\ %{}) do
    require Audit.Logger
    entry = Audit.Logger.build_entry(actor_id, action, metadata)
    persist(entry)
    broadcast(entry)
    {:ok, entry}
  end

  def log_security_event(actor_id, action, metadata) do
    require Audit.Logger
    entry =
      actor_id
      |> Audit.Logger.build_entry(action, metadata)
      |> Map.put(:level, :critical)

    persist(entry)
    broadcast(entry)
    alert_security_team(entry)
    {:ok, entry}
  end

  def log_bulk(events) when is_list(events) do
    require Audit.Logger

    entries =
      Enum.map(events, fn {actor_id, action, meta} ->
        Audit.Logger.build_entry(actor_id, action, meta)
      end)

    Enum.each(entries, &persist/1)
    {:ok, length(entries)}
  end

  def fetch_history(actor_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    since = Keyword.get(opts, :since, ~U[2000-01-01 00:00:00Z])

    audit_repo().all_for_actor(actor_id, limit: limit, since: since)
  end

  def fetch_by_action(action, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    audit_repo().all_for_action(to_string(action), limit: limit)
  end

  def redact_sensitive(entry) do
    redacted_meta = Map.drop(entry.metadata, [:password, :token, :secret])
    %{entry | metadata: redacted_meta}
  end

  defp persist(entry) do
    case audit_repo().insert(entry) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.error("Audit persist failed: #{inspect(reason)}")
        :error
    end
  end

  defp broadcast(entry) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "audit:events",
      {:audit_event, entry}
    )
  end

  defp alert_security_team(entry) do
    Notifications.Dispatcher.send_email(
      Application.get_env(:audit, :security_email),
      "Security Alert: #{entry.action}",
      "<p>Actor #{entry.actor_id} performed #{entry.action}</p>"
    )
  end

  defp audit_repo, do: Application.get_env(:audit, :repo_module)
end
```

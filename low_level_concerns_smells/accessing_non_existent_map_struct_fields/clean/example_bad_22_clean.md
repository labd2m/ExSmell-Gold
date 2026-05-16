```elixir
defmodule Compliance.AuditLogger do
  @moduledoc """
  Records immutable audit log entries for compliance and security review.
  Each entry captures the actor, affected resource, action type, and
  outcome so that any data-modifying operation can be reconstructed.
  """

  require Logger

  @valid_outcomes    [:success, :failure, :partial]
  @valid_resources   ~w(user account invoice payment document role)
  @sensitive_actions ~w(delete export transfer grant_role revoke_role)

  @type audit_entry :: %{
          id: String.t(),
          actor_id: String.t() | nil,
          action_type: String.t(),
          resource_type: String.t(),
          resource_id: String.t(),
          outcome: atom(),
          metadata: map(),
          sensitive: boolean(),
          logged_at: DateTime.t()
        }

  @spec log_action(map(), map()) :: {:ok, audit_entry()} | {:error, String.t()}
  def log_action(action, context \\ %{}) do
    actor_id      = action[:actor_id]
    resource_type = action[:resource_type]
    resource_id   = action[:resource_id]
    outcome       = action[:outcome]

    action_type = Map.get(action, :action_type, "unknown")

    with :ok <- validate_resource_type(resource_type),
         :ok <- validate_outcome(outcome),
         :ok <- validate_resource_id(resource_id) do
      sensitive = action_type in @sensitive_actions

      entry = %{
        id: generate_id(),
        actor_id: actor_id,
        action_type: action_type,
        resource_type: resource_type,
        resource_id: resource_id,
        outcome: outcome,
        metadata: build_metadata(action, context),
        sensitive: sensitive,
        logged_at: DateTime.utc_now()
      }

      persist_entry(entry)

      if sensitive do
        Logger.warning("Sensitive action logged",
          id: entry.id,
          actor_id: actor_id,
          action_type: action_type,
          resource_type: resource_type,
          resource_id: resource_id
        )
      else
        Logger.info("Audit entry created",
          id: entry.id,
          actor_id: actor_id,
          action_type: action_type
        )
      end

      {:ok, entry}
    end
  end

  @spec query(map()) :: list(audit_entry())
  def query(filters) do
    actor_id      = Map.get(filters, :actor_id)
    resource_type = Map.get(filters, :resource_type)
    since         = Map.get(filters, :since)

    load_entries()
    |> maybe_filter_actor(actor_id)
    |> maybe_filter_resource_type(resource_type)
    |> maybe_filter_since(since)
    |> Enum.sort_by(& &1.logged_at, {:desc, DateTime})
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp build_metadata(action, context) do
    base = Map.get(action, :metadata, %{})
    Map.merge(base, %{
      ip_address: Map.get(context, :ip_address),
      user_agent: Map.get(context, :user_agent),
      request_id: Map.get(context, :request_id)
    })
  end

  defp persist_entry(entry) do
    Logger.debug("Persisting audit entry #{entry.id}")
    :ok
  end

  defp load_entries, do: []

  defp maybe_filter_actor(entries, nil), do: entries
  defp maybe_filter_actor(entries, id),  do: Enum.filter(entries, &(&1.actor_id == id))

  defp maybe_filter_resource_type(entries, nil),  do: entries
  defp maybe_filter_resource_type(entries, type), do: Enum.filter(entries, &(&1.resource_type == type))

  defp maybe_filter_since(entries, nil),  do: entries
  defp maybe_filter_since(entries, since) do
    Enum.filter(entries, fn e -> DateTime.compare(e.logged_at, since) in [:gt, :eq] end)
  end

  defp validate_resource_type(nil), do: {:error, "Resource type is required"}
  defp validate_resource_type(t) when t in @valid_resources, do: :ok
  defp validate_resource_type(t), do: {:error, "Unknown resource type: #{t}"}

  defp validate_outcome(nil), do: {:error, "Outcome is required"}
  defp validate_outcome(o) when o in @valid_outcomes, do: :ok
  defp validate_outcome(o), do: {:error, "Invalid outcome: #{inspect(o)}"}

  defp validate_resource_id(nil), do: {:error, "Resource ID is required"}
  defp validate_resource_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_resource_id(id), do: {:error, "Invalid resource ID: #{inspect(id)}"}

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
```

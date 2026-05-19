# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `AuthAuditFlusher.flush/2` — the `send/2` call that delivers the full batch of authentication event records to the audit store process
- **Affected function(s):** `AuthAuditFlusher.flush/2`, `AuthAuditStore.handle_info/2`
- **Short explanation:** The entire in-memory buffer of authentication events — a large list of maps with device fingerprints, geo data, and session metadata — is sent in one message to the audit store process. The deep copy of this buffer blocks the flusher process; frequent flushes under heavy login load can cause the flusher to fall behind and increase the risk of data loss.

---

```elixir
defmodule AuthAuditStore do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{total_stored: 0, batches: 0}, opts)
  end

  def stats(pid), do: GenServer.call(pid, :stats)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:audit_batch, tenant_id, events}, state) do
    Logger.info("AuthAuditStore: persisting #{length(events)} auth events for tenant=#{tenant_id}")

    Enum.each(events, &persist_event/1)

    new_state = %{state |
      total_stored: state.total_stored + length(events),
      batches: state.batches + 1
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp persist_event(_event), do: :ok
end

defmodule AuthAuditFlusher do
  require Logger

  @doc """
  Drains the in-memory authentication event buffer for a given tenant and
  forwards all buffered events to the persistent audit store. Called
  periodically by a scheduler or on buffer-full triggers.
  """
  def flush(store_pid, tenant_id) do
    Logger.info("AuthAuditFlusher: draining event buffer for tenant=#{tenant_id}")

    events = drain_buffer(tenant_id)

    if events == [] do
      Logger.debug("AuthAuditFlusher: buffer empty, nothing to flush")
      :ok
    else
      Logger.info("AuthAuditFlusher: #{length(events)} events — sending to audit store")

      # VALIDATION: SMELL START - Large messages
      # VALIDATION: This is a smell because the complete buffer of authentication
      # events — potentially thousands of maps per flush, each carrying device
      # fingerprints, IP geolocation data, session metadata, and risk scores —
      # is deep-copied into the AuthAuditStore process mailbox as a single
      # send/2 call. The flusher process is blocked for the duration of the
      # copy. Under high-traffic authentication scenarios (e.g. mass SSO login
      # bursts), frequent flushes amplify this blocking significantly.
      send(store_pid, {:audit_batch, tenant_id, events})
      # VALIDATION: SMELL END

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate draining a large authentication event buffer
  # ---------------------------------------------------------------------------

  defp drain_buffer(tenant_id) do
    Enum.map(1..18_000, fn n ->
      %{
        event_id: "EVT-#{tenant_id}-#{:rand.uniform(1_000_000_000)}",
        tenant_id: tenant_id,
        user_id: "USR-#{:rand.uniform(500_000)}",
        event_type: Enum.random([:login_success, :login_failure, :mfa_challenge, :token_refresh, :logout]),
        ip_address: "#{:rand.uniform(255)}.#{:rand.uniform(255)}.#{:rand.uniform(255)}.#{:rand.uniform(255)}",
        geo: %{
          country_code: Enum.random(["US", "BR", "DE", "JP", "FR"]),
          city: Enum.random(["New York", "São Paulo", "Berlin", "Tokyo", "Paris"]),
          lat: :rand.uniform() * 180 - 90,
          lng: :rand.uniform() * 360 - 180,
          asn: "AS#{:rand.uniform(65_000)}"
        },
        device: %{
          fingerprint: Base.encode16(:crypto.strong_rand_bytes(16)),
          user_agent: "Mozilla/5.0 (compatible; App/#{n})",
          platform: Enum.random(["web", "ios", "android"]),
          trusted: Enum.random([true, false])
        },
        session: %{
          session_id: Base.encode64(:crypto.strong_rand_bytes(24)),
          duration_ms: :rand.uniform(3_600_000),
          mfa_used: Enum.random([true, false])
        },
        risk_score: :rand.uniform() |> Float.round(4),
        occurred_at: DateTime.add(~U[2024-06-15 00:00:00Z], n, :second)
      }
    end)
  end
end
```

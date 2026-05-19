# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `UserExportJob.run/2` — the `send/2` call that sends the full user profile list to the serialiser process
- **Affected function(s):** `UserExportJob.run/2`, `UserExportSerializer.handle_info/2`
- **Short explanation:** The complete list of enriched user profile maps — covering all active users with preferences, address data, and subscription details — is sent in one message to the serialiser process. The copy of this structure blocks the job process and, because exports may be triggered concurrently for multiple organisations, can cause the serialiser's mailbox to fill up with large pending messages.

---

```elixir
defmodule UserExportSerializer do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{exports: []}, opts)
  end

  def list_exports(pid), do: GenServer.call(pid, :list_exports)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:list_exports, _from, state), do: {:reply, state.exports, state}

  @impl true
  def handle_info({:export_users, org_id, users}, state) do
    Logger.info("UserExportSerializer: serialising #{length(users)} users for org=#{org_id}")

    csv_path = write_csv(org_id, users)

    export_record = %{org_id: org_id, path: csv_path, user_count: length(users), created_at: DateTime.utc_now()}

    {:noreply, %{state | exports: [export_record | state.exports]}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp write_csv(org_id, _users) do
    "/tmp/exports/org_#{org_id}_#{System.os_time(:second)}.csv"
  end
end

defmodule UserExportJob do
  require Logger

  @doc """
  Loads all active user profiles for the given organisation, enriches them
  with subscription and preference data, then dispatches the full dataset to
  the serialiser process for CSV generation and storage.
  """
  def run(serialiser_pid, org_id) do
    Logger.info("UserExportJob: loading users for org=#{org_id}")

    users = load_users(org_id)

    Logger.info("UserExportJob: #{length(users)} users loaded — sending to serialiser")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because the full list of enriched user profile
    # maps (up to 60 000 per organisation, each containing personal data,
    # nested address maps, preference trees, and subscription history) is
    # deep-copied into the UserExportSerializer mailbox as one send/2 call.
    # The job process is blocked during the copy, and concurrent exports for
    # multiple organisations simultaneously flood the serialiser's mailbox
    # with multiple huge pending messages.
    send(serialiser_pid, {:export_users, org_id, users})
    # VALIDATION: SMELL END

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate loading and enriching user profiles
  # ---------------------------------------------------------------------------

  defp load_users(org_id) do
    Enum.map(1..60_000, fn n ->
      user_id = "USR-#{org_id}-#{String.pad_leading(Integer.to_string(n), 8, "0")}"

      %{
        id: user_id,
        org_id: org_id,
        email: "user#{n}@org#{org_id}.example.com",
        name: "User #{n}",
        role: Enum.random([:admin, :member, :viewer, :billing]),
        status: Enum.random([:active, :inactive, :suspended]),
        address: %{
          street: "#{:rand.uniform(9999)} Main St",
          city: Enum.random(["Austin", "Berlin", "Tokyo", "London", "Sydney"]),
          country: Enum.random(["US", "DE", "JP", "GB", "AU"]),
          postal_code: "#{:rand.uniform(99999)}"
        },
        preferences: %{
          language: Enum.random(["en", "de", "ja", "pt"]),
          notifications: %{
            email: Enum.random([true, false]),
            sms: Enum.random([true, false]),
            push: Enum.random([true, false])
          },
          theme: Enum.random([:light, :dark, :system])
        },
        subscription: %{
          plan: Enum.random([:free, :pro, :enterprise]),
          started_at: ~U[2023-01-01 00:00:00Z],
          renews_at: ~U[2025-01-01 00:00:00Z],
          seats: :rand.uniform(500),
          add_ons: Enum.take_random(["sso", "audit_log", "api_access", "custom_roles"], :rand.uniform(4))
        },
        created_at: DateTime.add(~U[2020-01-01 00:00:00Z], n * 3600, :second),
        last_login_at: DateTime.add(~U[2024-06-01 00:00:00Z], :rand.uniform(2_592_000), :second)
      }
    end)
  end
end
```

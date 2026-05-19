```elixir
defmodule Auth.AuditEntry do
  @moduledoc "Represents a single authentication audit event."

  @enforce_keys [:event_id, :user_id, :action, :timestamp]
  defstruct [
    :event_id,
    :user_id,
    :action,
    :timestamp,
    :ip_address,
    :user_agent,
    :session_id,
    :request_headers,
    :geo_data,
    :outcome,
    :error_detail
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          user_id: String.t(),
          action: :login | :logout | :password_change | :mfa_challenge | :token_refresh,
          timestamp: DateTime.t(),
          ip_address: String.t(),
          user_agent: String.t(),
          session_id: String.t(),
          request_headers: map(),
          geo_data: map(),
          outcome: :success | :failure,
          error_detail: String.t() | nil
        }
end

defmodule Auth.AuditBuffer do
  @moduledoc "ETS-backed in-memory buffer for audit entries."

  @table :audit_buffer

  def setup do
    :ets.new(@table, [:named_table, :public, :bag])
  end

  @spec add(Auth.AuditEntry.t()) :: true
  def add(%Auth.AuditEntry{} = entry) do
    :ets.insert(@table, {:entry, entry})
  end

  @spec drain() :: list(Auth.AuditEntry.t())
  def drain do
    entries = :ets.lookup(@table, :entry) |> Enum.map(fn {:entry, e} -> e end)
    :ets.delete_all_objects(@table)
    entries
  end

  def populate_sample(count) do
    Enum.each(1..count, fn i ->
      add(%Auth.AuditEntry{
        event_id: "EVT-#{i}",
        user_id: "USR-#{rem(i, 1_000)}",
        action: Enum.random([:login, :logout, :mfa_challenge, :token_refresh]),
        timestamp: DateTime.utc_now(),
        ip_address: "192.168.#{rem(i, 255)}.#{rem(i * 3, 255)}",
        user_agent: "Mozilla/5.0 (compatible; App/2.0) RequestID=#{i}",
        session_id: "SESS-#{:crypto.strong_rand_bytes(16) |> Base.encode16()}",
        request_headers: %{
          "accept" => "application/json",
          "authorization" => "Bearer token_#{i}",
          "x-forwarded-for" => "10.0.#{rem(i, 255)}.1",
          "x-request-id" => "req-#{i}",
          "content-type" => "application/json"
        },
        geo_data: %{
          country: "BR",
          region: "SP",
          city: "São Paulo",
          lat: -23.5505,
          lng: -46.6333,
          isp: "ISP-#{rem(i, 10)}"
        },
        outcome: if(rem(i, 20) == 0, do: :failure, else: :success),
        error_detail: if(rem(i, 20) == 0, do: "invalid_credentials", else: nil)
      })
    end)
  end
end

defmodule Auth.AuditWriter do
  @moduledoc "GenServer that persists audit entries to permanent storage."
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_cast({:write_entries, entries}, state) do
    # Simulate persistence — in production this would batch-insert to the DB
    Enum.each(entries, fn _entry -> :ok end)
    {:noreply, [length(entries) | state]}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{batches: length(state), total: Enum.sum(state)}, state}
  end
end

defmodule Auth.AuditFlusher do
  @moduledoc "Periodically drains the audit buffer and writes entries to AuditWriter."

  require Logger

  @spec flush(pid()) :: :ok
  def flush(writer_pid) do
    entries = Auth.AuditBuffer.drain()

    Logger.info("Flushing #{length(entries)} audit entries to writer")

    GenServer.cast(writer_pid, {:write_entries, entries})

    :ok
  end
end
```

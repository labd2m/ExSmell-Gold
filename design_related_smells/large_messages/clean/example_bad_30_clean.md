```elixir
defmodule AuditLog.RequestContext do
  defstruct [:method, :path, :headers, :body, :query_params, :remote_ip]

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: map() | nil,
          query_params: map(),
          remote_ip: String.t()
        }
end

defmodule AuditLog.ResponseContext do
  defstruct [:status, :body, :duration_ms, :headers]

  @type t :: %__MODULE__{
          status: pos_integer(),
          body: map() | nil,
          duration_ms: non_neg_integer(),
          headers: [{String.t(), String.t()}]
        }
end

defmodule AuditLog.Entry do
  @enforce_keys [:id, :actor_id, :action, :resource, :occurred_at, :outcome]
  defstruct [
    :id,
    :actor_id,
    :actor_ip,
    :action,
    :resource,
    :resource_id,
    :occurred_at,
    :outcome,
    :request,
    :response,
    :stack_trace,
    :metadata,
    :tenant_id
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          actor_id: String.t(),
          actor_ip: String.t(),
          action: String.t(),
          resource: String.t(),
          resource_id: String.t() | nil,
          occurred_at: DateTime.t(),
          outcome: :success | :failure | :error,
          request: AuditLog.RequestContext.t(),
          response: AuditLog.ResponseContext.t(),
          stack_trace: String.t() | nil,
          metadata: map(),
          tenant_id: String.t()
        }
end

defmodule AuditLog.Buffer do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def drain, do: GenServer.call(__MODULE__, :drain, 60_000)

  @impl true
  def init(_), do: {:ok, build_buffer()}

  @impl true
  def handle_call(:drain, _from, buffer) do
    {:reply, buffer, []}
  end

  defp build_buffer do
    now = DateTime.utc_now()
    actions = ["user.login", "user.logout", "invoice.create", "payment.process", "role.assign"]
    resources = ["User", "Invoice", "Payment", "Role", "Report"]

    Enum.map(1..100_000, fn n ->
      failed = rem(n, 20) == 0

      %AuditLog.Entry{
        id: "audit_#{n}_#{:rand.uniform(999_999_999)}",
        actor_id: "usr_#{rem(n, 50_000) + 1}",
        actor_ip: "192.168.#{rem(n, 255)}.#{rem(n * 3, 255)}",
        action: Enum.random(actions),
        resource: Enum.random(resources),
        resource_id: "res_#{rem(n, 100_000)}",
        occurred_at: DateTime.add(now, -:rand.uniform(86_400), :second),
        outcome: if(failed, do: :failure, else: :success),
        tenant_id: "tenant_#{rem(n, 500) + 1}",
        metadata: %{
          user_agent: "Mozilla/5.0 (compatible; App/3.0)",
          correlation_id: "corr_#{n}_#{:rand.uniform(999_999)}",
          feature_flags: %{beta: rem(n, 5) == 0, dark_mode: rem(n, 3) == 0}
        },
        stack_trace:
          if failed do
            "** (RuntimeError) something went wrong\n" <>
              String.duplicate("    (app 1.0.0) lib/module_#{rem(n, 20)}.ex:#{rem(n, 200)}: Module.func/2\n", 8)
          end,
        request: %AuditLog.RequestContext{
          method: Enum.random(["GET", "POST", "PUT", "DELETE"]),
          path: "/api/v2/#{String.downcase(Enum.random(resources))}/#{rem(n, 100_000)}",
          headers: [
            {"content-type", "application/json"},
            {"accept", "application/json"},
            {"x-request-id", "req_#{n}"}
          ],
          body: %{
            data: %{attribute_1: "value_#{n}", attribute_2: rem(n, 100), nested: %{key: "val"}},
            meta: %{version: "2", timestamp: DateTime.to_iso8601(now)}
          },
          query_params: %{page: rem(n, 100), per_page: 50},
          remote_ip: "203.0.#{rem(n, 255)}.#{rem(n * 7, 255)}"
        },
        response: %AuditLog.ResponseContext{
          status: if(failed, do: 422, else: 200),
          body: %{data: %{id: "res_#{n}", type: "result"}, meta: %{took_ms: :rand.uniform(500)}},
          duration_ms: :rand.uniform(2000),
          headers: [{"content-type", "application/json"}, {"x-request-id", "req_#{n}"}]
        }
      }
    end)
  end
end

defmodule AuditLog.ArchiverWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:archive_batch, tenant, entries}, _state) do
    {:noreply, {tenant, length(entries)}}
  end
end

defmodule AuditLog.Exporter do
  @moduledoc """
  Drains the in-memory audit log buffer and ships all entries to
  the archiver worker for long-term storage.
  """

  require Logger

  @spec ship_to_archiver(pid(), String.t()) :: :ok
  def ship_to_archiver(archiver_pid, tenant_id) do
    Logger.info("Draining audit log buffer for tenant #{tenant_id}...")

    entries = AuditLog.Buffer.drain()

    tenant_entries = Enum.filter(entries, &(&1.tenant_id == tenant_id))

    Logger.info(
      "Found #{length(tenant_entries)} entries for tenant #{tenant_id}. Shipping to archiver..."
    )

    send(archiver_pid, {:archive_batch, tenant_id, tenant_entries})

    Logger.info("Audit batch shipped for tenant #{tenant_id}.")
    :ok
  end
end
```

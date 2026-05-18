# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `RouteDispatcher.dispatch/2`, line where `String.to_atom/1` is called |
| **Affected function(s)** | `RouteDispatcher.dispatch/2` |
| **Short explanation** | The function receives a `service` string from an external HTTP request and converts it directly to an atom using `String.to_atom/1`. Since the value originates from user-controlled input, an unbounded number of distinct atoms can be created at runtime, exhausting BEAM's atom table. |

```elixir
defmodule MyApp.RouteDispatcher do
  @moduledoc """
  Dispatches incoming API requests to the appropriate internal service handler
  based on the `service` field present in the request payload.
  """

  require Logger

  @known_handlers %{
    billing: MyApp.Handlers.Billing,
    inventory: MyApp.Handlers.Inventory,
    notifications: MyApp.Handlers.Notifications,
    reporting: MyApp.Handlers.Reporting,
    authentication: MyApp.Handlers.Authentication
  }

  @default_timeout_ms 5_000

  @doc """
  Dispatches a decoded request map to the correct handler module.

  The `request` map is expected to have at minimum:
    - `"service"` – name of the target service (string)
    - `"action"`  – name of the action to invoke (string)
    - `"payload"` – map of parameters for the action
  """
  @spec dispatch(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch(request, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    request_id = Map.get(request, "request_id", generate_request_id())

    Logger.metadata(request_id: request_id)
    Logger.info("Dispatching request", service: request["service"], action: request["action"])

    with {:ok, service_atom} <- resolve_service(request["service"]),
         {:ok, action_atom} <- resolve_action(request["action"]),
         {:ok, handler} <- find_handler(service_atom),
         {:ok, result} <- invoke_handler(handler, action_atom, request["payload"], timeout) do
      Logger.info("Request dispatched successfully")
      {:ok, %{request_id: request_id, result: result}}
    else
      {:error, reason} = err ->
        Logger.warning("Dispatch failed", reason: inspect(reason))
        err
    end
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is called with a value
  # that comes directly from external HTTP request data. Any arbitrary string sent
  # by a client will be permanently allocated as a new atom in BEAM's atom table,
  # which is capped at 1_048_576 entries. A malicious or misbehaving caller can
  # exhaust the atom table and crash the node.
  defp resolve_service(nil), do: {:error, :missing_service}

  defp resolve_service(service) when is_binary(service) do
    atom = String.to_atom(service)
    {:ok, atom}
  end
  # VALIDATION: SMELL END

  defp resolve_action(nil), do: {:error, :missing_action}

  defp resolve_action(action) when is_binary(action) do
    case Enum.find([:create, :read, :update, :delete, :list, :search], &(Atom.to_string(&1) == action)) do
      nil -> {:error, {:unknown_action, action}}
      atom -> {:ok, atom}
    end
  end

  defp find_handler(service_atom) do
    case Map.fetch(@known_handlers, service_atom) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, {:unknown_service, service_atom}}
    end
  end

  defp invoke_handler(handler, action, payload, timeout) do
    task =
      Task.async(fn ->
        handler.handle(action, payload || %{})
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :handler_timeout}
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```

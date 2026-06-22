```elixir
defmodule Platform.RequestContext do
  @moduledoc """
  A request-scoped key-value store backed by the calling process's dictionary.

  Values are stored in the process dictionary under a namespaced key, making
  them available anywhere within the same request process without threading
  context through every function call. The store is automatically cleaned up
  when the process exits.

  Intended for cross-cutting concerns: trace IDs, current user, request ID,
  feature flags resolved at request start.
  """

  @namespace :__request_context__

  @type key :: atom()
  @type value :: term()

  @doc "Stores a value in the request context under `key`."
  @spec put(key(), value()) :: :ok
  def put(key, value) when is_atom(key) do
    Process.put({@namespace, key}, value)
    :ok
  end

  @doc "Stores multiple key-value pairs at once."
  @spec put_all(keyword() | map()) :: :ok
  def put_all(pairs) when is_list(pairs) or is_map(pairs) do
    Enum.each(pairs, fn {k, v} -> put(k, v) end)
    :ok
  end

  @doc "Retrieves a value by `key`. Returns `default` if not set."
  @spec get(key(), term()) :: value()
  def get(key, default \\ nil) when is_atom(key) do
    Process.get({@namespace, key}, default)
  end

  @doc """
  Retrieves a value by `key`. Returns `{:ok, value}` or `{:error, :not_found}`.
  """
  @spec fetch(key()) :: {:ok, value()} | {:error, :not_found}
  def fetch(key) when is_atom(key) do
    case Process.get({@namespace, key}, :__not_set__) do
      :__not_set__ -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @doc "Returns `true` if `key` is set in the current request context."
  @spec set?(key()) :: boolean()
  def set?(key) when is_atom(key) do
    Process.get({@namespace, key}, :__not_set__) != :__not_set__
  end

  @doc "Removes a key from the request context."
  @spec delete(key()) :: :ok
  def delete(key) when is_atom(key) do
    Process.delete({@namespace, key})
    :ok
  end

  @doc "Returns all currently set context values as a map."
  @spec all() :: map()
  def all do
    Process.get()
    |> Enum.flat_map(fn
      {{@namespace, key}, value} -> [{key, value}]
      _ -> []
    end)
    |> Map.new()
  end

  @doc "Clears all request context values."
  @spec clear() :: :ok
  def clear do
    Process.get()
    |> Enum.each(fn
      {{@namespace, _key} = full_key, _} -> Process.delete(full_key)
      _ -> :ok
    end)

    :ok
  end
end

defmodule AppWeb.Plugs.SetRequestContext do
  @moduledoc """
  A Plug that populates `Platform.RequestContext` from the incoming connection
  at the start of each request, making trace IDs and user identity available
  globally within the request process.
  """

  import Plug.Conn
  alias Platform.RequestContext

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    request_id = conn |> get_resp_header("x-request-id") |> List.first(generate_id())
    trace_id = conn |> get_req_header("x-trace-id") |> List.first(request_id)

    RequestContext.put_all(%{
      request_id: request_id,
      trace_id: trace_id,
      remote_ip: format_ip(conn.remote_ip),
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    })

    if account = conn.assigns[:current_account] do
      RequestContext.put(:current_account_id, account.id)
    end

    register_before_send(conn, fn sent_conn ->
      RequestContext.clear()
      sent_conn
    end)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(other), do: inspect(other)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```

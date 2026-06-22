```elixir
defmodule Platform.ApiStub do
  @moduledoc """
  A Plug-based API stub server for integration testing.

  Tests register expected request-response pairs before exercising
  the system under test. The stub matches incoming requests against
  registered expectations and returns the configured response.
  Unmatched requests return 500 with a diagnostic body.
  """

  use Agent

  import Plug.Conn

  @behaviour Plug

  @type matcher :: %{method: String.t(), path: String.t(), query: map()}
  @type stub_response :: %{status: pos_integer(), body: term(), headers: [{String.t(), String.t()}]}
  @type stub :: %{matcher: matcher(), response: stub_response(), call_count: non_neg_integer()}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{stubs: [], calls: []} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers a stub that matches `method` and `path`, responding with `response`.
  """
  @spec register(String.t(), String.t(), stub_response(), map()) :: :ok
  def register(method, path, response, query \\ %{}) do
    matcher = %{method: String.upcase(method), path: path, query: query}
    stub = %{matcher: matcher, response: response, call_count: 0}
    Agent.update(__MODULE__, fn state ->
      %{state | stubs: [stub | state.stubs]}
    end)
  end

  @doc "Clears all registered stubs and call history."
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> %{stubs: [], calls: []} end)

  @doc "Returns the list of all recorded calls."
  @spec calls() :: [map()]
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc "Returns the call count for a given method and path."
  @spec call_count(String.t(), String.t()) :: non_neg_integer()
  def call_count(method, path) do
    calls()
    |> Enum.count(fn c -> c.method == String.upcase(method) and c.path == path end)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    query_params = conn |> fetch_query_params() |> Map.get(:query_params, %{})
    record_call(conn, query_params)

    case find_stub(conn.method, conn.request_path, query_params) do
      {:ok, stub} ->
        increment_call_count(stub)
        send_stub_response(conn, stub.response)

      :not_found ->
        send_unmatched(conn)
    end
  end

  defp find_stub(method, path, query_params) do
    stubs = Agent.get(__MODULE__, & &1.stubs)

    Enum.find_value(stubs, :not_found, fn stub ->
      if matches?(stub.matcher, method, path, query_params) do
        {:ok, stub}
      end
    end)
  end

  defp matches?(%{method: m, path: p, query: q}, method, path, params) do
    m == method and
      path_matches?(p, path) and
      Enum.all?(q, fn {k, v} -> Map.get(params, k) == v end)
  end

  defp path_matches?(pattern, path) when is_binary(pattern) do
    pattern == path or Regex.match?(~r/^#{Regex.escape(pattern)}$/, path)
  end

  defp send_stub_response(conn, %{status: status, body: body, headers: headers}) do
    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)

    encoded = if is_map(body) or is_list(body), do: Jason.encode!(body), else: to_string(body)
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, encoded)
    |> halt()
  end

  defp send_unmatched(conn) do
    body = Jason.encode!(%{
      error: "no_stub_matched",
      method: conn.method,
      path: conn.request_path
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, body)
    |> halt()
  end

  defp record_call(conn, query_params) do
    call = %{method: conn.method, path: conn.request_path, query: query_params, at: DateTime.utc_now()}
    Agent.update(__MODULE__, fn s -> %{s | calls: [call | s.calls]} end)
  end

  defp increment_call_count(%{matcher: matcher}) do
    Agent.update(__MODULE__, fn state ->
      updated = Enum.map(state.stubs, fn stub ->
        if stub.matcher == matcher do
          %{stub | call_count: stub.call_count + 1}
        else
          stub
        end
      end)
      %{state | stubs: updated}
    end)
  end
end
```

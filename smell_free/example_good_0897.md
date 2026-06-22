```elixir
defmodule Capability.Token do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          principal_id: String.t(),
          scopes: MapSet.t(),
          issued_at: integer(),
          expires_at: integer(),
          parent_id: String.t() | nil
        }

  defstruct [:id, :principal_id, :scopes, :issued_at, :expires_at, :parent_id]

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: exp}), do: System.system_time(:second) > exp

  @spec has_scope?(t(), String.t()) :: boolean()
  def has_scope?(%__MODULE__{scopes: scopes}, scope), do: MapSet.member?(scopes, scope)

  @spec covers_scopes?(t(), [String.t()]) :: boolean()
  def covers_scopes?(%__MODULE__{scopes: scopes}, required) do
    required_set = MapSet.new(required)
    MapSet.subset?(required_set, scopes)
  end
end

defmodule Capability.TokenStore do
  @moduledoc """
  Issues and verifies scoped delegation tokens backed by ETS.

  A root token is issued for a principal with a full scope set. Delegated
  tokens are derived from a parent token but may only carry a subset of the
  parent's scopes — you cannot escalate privileges through delegation.
  Tokens are revocable; revocation cascades to all tokens whose `parent_id`
  traces back to the revoked token.
  """

  use GenServer

  alias Capability.Token

  @default_ttl_seconds 3_600
  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec issue(String.t(), [String.t()], keyword()) :: {:ok, Token.t()}
  def issue(principal_id, scopes, opts \\ []) when is_binary(principal_id) and is_list(scopes) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    now = System.system_time(:second)
    token = %Token{
      id: generate_id(),
      principal_id: principal_id,
      scopes: MapSet.new(scopes),
      issued_at: now,
      expires_at: now + ttl,
      parent_id: nil
    }
    GenServer.call(__MODULE__, {:store, token})
    {:ok, token}
  end

  @spec delegate(Token.t(), [String.t()], keyword()) ::
          {:ok, Token.t()} | {:error, :expired | :scope_escalation}
  def delegate(%Token{} = parent, requested_scopes, opts \\ []) when is_list(requested_scopes) do
    cond do
      Token.expired?(parent) ->
        {:error, :expired}

      not Token.covers_scopes?(parent, requested_scopes) ->
        {:error, :scope_escalation}

      true ->
        ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
        now = System.system_time(:second)
        token = %Token{
          id: generate_id(),
          principal_id: parent.principal_id,
          scopes: MapSet.new(requested_scopes),
          issued_at: now,
          expires_at: min(now + ttl, parent.expires_at),
          parent_id: parent.id
        }
        GenServer.call(__MODULE__, {:store, token})
        {:ok, token}
    end
  end

  @spec verify(String.t(), [String.t()]) ::
          {:ok, Token.t()} | {:error, :not_found | :expired | :revoked | :insufficient_scope}
  def verify(token_id, required_scopes \\ []) when is_binary(token_id) do
    case :ets.lookup(@table, token_id) do
      [] ->
        {:error, :not_found}

      [{^token_id, :revoked}] ->
        {:error, :revoked}

      [{^token_id, %Token{} = token}] ->
        cond do
          Token.expired?(token) -> {:error, :expired}
          not Token.covers_scopes?(token, required_scopes) -> {:error, :insufficient_scope}
          true -> {:ok, token}
        end
    end
  end

  @spec revoke(String.t()) :: :ok
  def revoke(token_id) when is_binary(token_id) do
    GenServer.call(__MODULE__, {:revoke, token_id})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:store, %Token{id: id} = token}, _from, state) do
    :ets.insert(@table, {id, token})
    {:reply, :ok, state}
  end

  def handle_call({:revoke, id}, _from, state) do
    :ets.insert(@table, {id, :revoked})
    revoke_children(id)
    {:reply, :ok, state}
  end

  defp revoke_children(parent_id) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn
      {id, %Token{parent_id: ^parent_id}} ->
        :ets.insert(@table, {id, :revoked})
        revoke_children(id)
      _ -> :ok
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```

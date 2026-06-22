```elixir
defmodule Caching.TokenStore do
  @moduledoc """
  In-memory store for short-lived access tokens, keyed by client identity.

  State mutations are routed exclusively through this module's public API,
  ensuring consistent TTL enforcement and preventing scattered direct access.
  """

  use Agent

  @type token_entry :: %{
          value: String.t(),
          expires_at: DateTime.t()
        }

  @doc false
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Stores a token for the given client key with an explicit expiry timestamp.
  """
  @spec put(String.t(), String.t(), DateTime.t()) :: :ok
  def put(client_id, token_value, expires_at)
      when is_binary(client_id) and is_binary(token_value) do
    Agent.update(__MODULE__, fn store ->
      Map.put(store, client_id, %{value: token_value, expires_at: expires_at})
    end)
  end

  @doc """
  Retrieves a valid, non-expired token for the given client.

  Returns `{:ok, token}` if found and unexpired, or `{:error, :not_found}` otherwise.
  """
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, :not_found | :expired}
  def fetch(client_id) when is_binary(client_id) do
    Agent.get(__MODULE__, fn store ->
      case Map.get(store, client_id) do
        nil -> {:error, :not_found}
        %{value: v, expires_at: exp} -> check_expiry(v, exp)
      end
    end)
  end

  @doc """
  Removes the token for a given client, forcing re-authentication on next access.
  """
  @spec revoke(String.t()) :: :ok
  def revoke(client_id) when is_binary(client_id) do
    Agent.update(__MODULE__, &Map.delete(&1, client_id))
  end

  @doc """
  Evicts all tokens that have passed their expiry time.

  Returns the number of entries evicted.
  """
  @spec evict_expired() :: non_neg_integer()
  def evict_expired do
    now = DateTime.utc_now()

    Agent.get_and_update(__MODULE__, fn store ->
      {valid, expired} = Map.split_with(store, fn {_k, entry} ->
        DateTime.compare(entry.expires_at, now) == :gt
      end)

      {map_size(expired), valid}
    end)
  end

  @doc """
  Returns the total number of stored token entries, including expired ones.
  """
  @spec size() :: non_neg_integer()
  def size do
    Agent.get(__MODULE__, &map_size/1)
  end

  # --- private ---

  defp check_expiry(value, expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      {:ok, value}
    else
      {:error, :expired}
    end
  end
end
```

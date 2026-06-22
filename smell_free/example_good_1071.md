**File:** `example_good_1071.md`

```elixir
defmodule Sessions.Store do
  @moduledoc """
  Session state registry backed by an Agent. All mutations are performed
  through this module's explicit API, keeping state management centralized
  and the data contract well-defined.
  """

  use Agent

  @type session_id :: String.t()
  @type session :: %{
          user_id: String.t(),
          started_at: DateTime.t(),
          last_active_at: DateTime.t(),
          metadata: map()
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec create(session_id(), String.t(), map()) :: {:ok, session()} | {:error, :already_exists}
  def create(session_id, user_id, metadata \\ %{})
      when is_binary(session_id) and is_binary(user_id) do
    now = DateTime.utc_now()

    session = %{
      user_id: user_id,
      started_at: now,
      last_active_at: now,
      metadata: metadata
    }

    updated =
      Agent.get_and_update(__MODULE__, fn state ->
        if Map.has_key?(state, session_id) do
          {{:error, :already_exists}, state}
        else
          {{:ok, session}, Map.put(state, session_id, session)}
        end
      end)

    updated
  end

  @spec fetch(session_id()) :: {:ok, session()} | :miss
  def fetch(session_id) when is_binary(session_id) do
    case Agent.get(__MODULE__, &Map.get(&1, session_id)) do
      nil -> :miss
      session -> {:ok, session}
    end
  end

  @spec touch(session_id()) :: :ok | {:error, :not_found}
  def touch(session_id) when is_binary(session_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state, session_id) do
        {:ok, session} ->
          updated = Map.put(state, session_id, %{session | last_active_at: DateTime.utc_now()})
          {:ok, updated}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  @spec put_metadata(session_id(), atom() | String.t(), term()) :: :ok | {:error, :not_found}
  def put_metadata(session_id, key, value) when is_binary(session_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state, session_id) do
        {:ok, session} ->
          updated_meta = Map.put(session.metadata, key, value)
          updated_session = %{session | metadata: updated_meta}
          updated_state = Map.put(state, session_id, updated_session)
          {:ok, updated_state}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  @spec delete(session_id()) :: :ok
  def delete(session_id) when is_binary(session_id) do
    Agent.update(__MODULE__, &Map.delete(&1, session_id))
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    Agent.get(__MODULE__, &map_size/1)
  end

  @spec list_for_user(String.t()) :: [{session_id(), session()}]
  def list_for_user(user_id) when is_binary(user_id) do
    Agent.get(__MODULE__, fn state ->
      state
      |> Enum.filter(fn {_id, session} -> session.user_id == user_id end)
      |> Enum.to_list()
    end)
  end

  @spec evict_stale(DateTime.t()) :: non_neg_integer()
  def evict_stale(%DateTime{} = cutoff) do
    Agent.get_and_update(__MODULE__, fn state ->
      {stale, active} = Enum.split_with(state, fn {_id, s} ->
        DateTime.compare(s.last_active_at, cutoff) == :lt
      end)

      {length(stale), Map.new(active)}
    end)
  end
end
```

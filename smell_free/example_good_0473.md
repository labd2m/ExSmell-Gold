```elixir
defmodule Cluster.LeaderElection do
  @moduledoc """
  Elects a single leader among all connected nodes using Erlang's `:pg`
  process groups.

  Every candidate process joins a named group on startup. Leadership is
  determined by selecting the process with the lexicographically smallest
  `{node(), pid()}` pair, which is stable and tie-free across the cluster.
  Candidates monitor the current leader and re-run election when it exits.
  """

  use GenServer

  require Logger

  @type opts :: [
          group: atom(),
          on_elected: (-> :ok),
          on_demoted: (-> :ok)
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    group = Keyword.fetch!(opts, :group)
    GenServer.start_link(__MODULE__, opts, name: via(group))
  end

  @spec leader(atom()) :: {:ok, pid()} | {:error, :no_candidates}
  def leader(group) when is_atom(group) do
    case :pg.get_members(group) do
      [] -> {:error, :no_candidates}
      members -> {:ok, elect(members)}
    end
  end

  @spec am_leader?(atom()) :: boolean()
  def am_leader?(group) when is_atom(group) do
    case leader(group) do
      {:ok, pid} -> pid == self()
      _ -> false
    end
  end

  @impl GenServer
  def init(opts) do
    group = Keyword.fetch!(opts, :group)
    :ok = :pg.join(group, self())

    state = %{
      group: group,
      leader_ref: nil,
      is_leader: false,
      on_elected: Keyword.get(opts, :on_elected, fn -> :ok end),
      on_demoted: Keyword.get(opts, :on_demoted, fn -> :ok end)
    }

    {:ok, run_election(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{leader_ref: ref} = state) do
    Logger.info("Leader exited, re-electing",
      group: state.group,
      reason: inspect(reason)
    )

    {:noreply, run_election(%{state | leader_ref: nil, is_leader: false})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_election(state) do
    members = :pg.get_members(state.group)

    case members do
      [] ->
        state

      candidates ->
        new_leader = elect(candidates)
        is_leader = new_leader == self()
        ref = if new_leader != self(), do: Process.monitor(new_leader), else: nil

        cond do
          is_leader and not state.is_leader ->
            Logger.info("Elected as leader", group: state.group, node: node())
            state.on_elected.()

          not is_leader and state.is_leader ->
            state.on_demoted.()

          true ->
            :ok
        end

        %{state | is_leader: is_leader, leader_ref: ref}
    end
  end

  defp elect(members) do
    Enum.min_by(members, fn pid -> {node(pid), pid} end)
  end

  defp via(group), do: {:via, Registry, {Cluster.Registry, {__MODULE__, group}}}
end
```

```elixir
defmodule Ops.ProcessInventory do
  @moduledoc """
  Enumerates all supervised processes in the running node and groups them
  by category: application children, named GenServers, task processes, and
  anonymous processes. Used by the operations dashboard and health checks
  to verify that all expected processes are running without inspecting the
  supervision tree directly.
  """

  @type process_info :: %{
          pid: pid(),
          name: atom() | nil,
          registered: boolean(),
          memory_bytes: non_neg_integer(),
          message_queue_len: non_neg_integer(),
          current_function: {module(), atom(), arity()} | nil
        }

  @type inventory :: %{
          named_servers: [process_info()],
          task_processes: [process_info()],
          other: [process_info()],
          total: non_neg_integer()
        }

  @doc "Returns a categorised inventory of all living processes on the node."
  @spec collect() :: inventory()
  def collect do
    all = Process.list()
    infos = Enum.map(all, &fetch_info/1)

    {named, unnamed} = Enum.split_with(infos, & &1.registered)
    {tasks, other} = Enum.split_with(unnamed, &task_process?/1)

    %{
      named_servers: Enum.sort_by(named, fn p -> Atom.to_string(p.name) end),
      task_processes: tasks,
      other: other,
      total: length(all)
    }
  end

  @doc "Returns true when a process with the given registered `name` is alive."
  @spec alive?(atom()) :: boolean()
  def alive?(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc "Returns the memory usage in bytes for the named process, or nil if absent."
  @spec memory_for(atom()) :: non_neg_integer() | nil
  def memory_for(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> nil
      pid ->
        case Process.info(pid, :memory) do
          {:memory, bytes} -> bytes
          nil -> nil
        end
    end
  end

  @doc "Returns all processes whose message queue exceeds `threshold` messages."
  @spec overloaded_processes(non_neg_integer()) :: [process_info()]
  def overloaded_processes(threshold) when is_integer(threshold) and threshold >= 0 do
    Process.list()
    |> Enum.map(&fetch_info/1)
    |> Enum.filter(fn info -> info.message_queue_len > threshold end)
    |> Enum.sort_by(& &1.message_queue_len, :desc)
  end

  defp fetch_info(pid) do
    keys = [:registered_name, :memory, :message_queue_len, :current_function]
    info = Process.info(pid, keys) || []

    name = info[:registered_name]

    %{
      pid: pid,
      name: if(name == [], do: nil, else: name),
      registered: is_atom(name) and name != [],
      memory_bytes: info[:memory] || 0,
      message_queue_len: info[:message_queue_len] || 0,
      current_function: info[:current_function]
    }
  end

  defp task_process?(%{current_function: {Task.Supervised, _, _}}), do: true
  defp task_process?(%{current_function: {Task.Server, _, _}}), do: true
  defp task_process?(_), do: false
end
```

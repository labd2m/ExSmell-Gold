```elixir
defmodule Metrics.Aggregator do
  @moduledoc """
  Collects and aggregates time-series metric samples per named counter or gauge.
  State is managed through a single, well-defined API module backed by an Agent.
  """

  @type metric_name :: String.t()
  @type sample :: %{value: number(), recorded_at: DateTime.t()}
  @type store :: %{metric_name() => [sample()]}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec record(metric_name(), number()) :: :ok
  def record(name, value) when is_binary(name) and is_number(value) do
    sample = %{value: value, recorded_at: DateTime.utc_now()}
    Agent.update(__MODULE__, &append_sample(&1, name, sample))
  end

  @spec average(metric_name()) :: {:ok, float()} | {:error, :no_data}
  def average(name) when is_binary(name) do
    Agent.get(__MODULE__, &fetch_samples(&1, name))
    |> compute_average()
  end

  @spec max(metric_name()) :: {:ok, number()} | {:error, :no_data}
  def max(name) when is_binary(name) do
    Agent.get(__MODULE__, &fetch_samples(&1, name))
    |> find_max()
  end

  @spec min(metric_name()) :: {:ok, number()} | {:error, :no_data}
  def min(name) when is_binary(name) do
    Agent.get(__MODULE__, &fetch_samples(&1, name))
    |> find_min()
  end

  @spec sample_count(metric_name()) :: non_neg_integer()
  def sample_count(name) when is_binary(name) do
    Agent.get(__MODULE__, fn store ->
      store |> Map.get(name, []) |> length()
    end)
  end

  @spec flush(metric_name()) :: :ok
  def flush(name) when is_binary(name) do
    Agent.update(__MODULE__, &Map.delete(&1, name))
  end

  @spec flush_all() :: :ok
  def flush_all do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end

  @spec recent_samples(metric_name(), pos_integer()) :: [sample()]
  def recent_samples(name, limit) when is_binary(name) and is_integer(limit) and limit > 0 do
    Agent.get(__MODULE__, fn store ->
      store
      |> Map.get(name, [])
      |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime})
      |> Enum.take(limit)
    end)
  end

  @spec append_sample(store(), metric_name(), sample()) :: store()
  defp append_sample(store, name, sample) do
    Map.update(store, name, [sample], &[sample | &1])
  end

  @spec fetch_samples(store(), metric_name()) :: [sample()]
  defp fetch_samples(store, name), do: Map.get(store, name, [])

  @spec compute_average([sample()]) :: {:ok, float()} | {:error, :no_data}
  defp compute_average([]), do: {:error, :no_data}

  defp compute_average(samples) do
    total = Enum.reduce(samples, 0, &(&1.value + &2))
    {:ok, total / length(samples)}
  end

  @spec find_max([sample()]) :: {:ok, number()} | {:error, :no_data}
  defp find_max([]), do: {:error, :no_data}
  defp find_max(samples), do: {:ok, Enum.max_by(samples, & &1.value).value}

  @spec find_min([sample()]) :: {:ok, number()} | {:error, :no_data}
  defp find_min([]), do: {:error, :no_data}
  defp find_min(samples), do: {:ok, Enum.min_by(samples, & &1.value).value}
end
```

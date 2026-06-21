```elixir
defmodule Pipeline.StageRunner do
  @moduledoc """
  Executes a sequence of named transformation stages against a shared
  accumulator. Each stage is a module implementing the `Pipeline.Stage`
  behaviour. The runner collects per-stage timings and stops at the first
  error, returning a structured result that includes all timings regardless
  of outcome.
  """

  @type stage_name :: atom()
  @type stage_module :: module()
  @type timing :: %{stage: stage_name(), duration_us: non_neg_integer()}
  @type run_result ::
          {:ok, term(), [timing()]}
          | {:error, stage_name(), term(), [timing()]}

  @doc """
  Runs `stages` in order, threading the accumulator through each one.
  Returns the final accumulator and per-stage timings on full success, or
  a tagged error with the failing stage name and partial timings.
  """
  @spec run([{stage_name(), stage_module()}], term()) :: run_result()
  def run(stages, initial_acc) when is_list(stages) do
    execute(stages, initial_acc, [])
  end

  defp execute([], acc, timings) do
    {:ok, acc, Enum.reverse(timings)}
  end

  defp execute([{name, mod} | rest], acc, timings) do
    {duration, result} = :timer.tc(fn -> mod.run(acc) end)
    timing = %{stage: name, duration_us: duration}

    case result do
      {:ok, new_acc} ->
        execute(rest, new_acc, [timing | timings])

      {:error, reason} ->
        {:error, name, reason, Enum.reverse([timing | timings])}
    end
  end
end

defmodule Pipeline.Stage do
  @moduledoc "Behaviour contract for a single pipeline transformation stage."

  @doc "Transforms the accumulator, returning a new value or an error reason."
  @callback run(acc :: term()) :: {:ok, term()} | {:error, term()}
end

defmodule Pipeline.Stages.SchemaNormaliser do
  @moduledoc "Normalises string keys to atom keys in a map accumulator."

  @behaviour Pipeline.Stage

  @impl Pipeline.Stage
  @spec run(map()) :: {:ok, map()} | {:error, :not_a_map}
  def run(acc) when is_map(acc) do
    normalised =
      Map.new(acc, fn
        {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
        {k, v} -> {k, v}
      end)

    {:ok, normalised}
  rescue
    ArgumentError -> {:error, :unknown_key_in_schema}
  end

  def run(_), do: {:error, :not_a_map}
end

defmodule Pipeline.Stages.RequiredFieldValidator do
  @moduledoc "Validates that all required fields are present and non-nil."

  @behaviour Pipeline.Stage

  @required_fields [:id, :type, :payload]

  @impl Pipeline.Stage
  @spec run(map()) :: {:ok, map()} | {:error, {:missing_fields, [atom()]}}
  def run(acc) when is_map(acc) do
    missing = Enum.reject(@required_fields, fn k -> Map.has_key?(acc, k) and acc[k] != nil end)

    if Enum.empty?(missing) do
      {:ok, acc}
    else
      {:error, {:missing_fields, missing}}
    end
  end

  def run(_), do: {:error, {:missing_fields, @required_fields}}
end
```

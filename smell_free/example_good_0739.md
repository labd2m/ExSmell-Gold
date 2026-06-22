```elixir
defprotocol Transform.Step do
  @moduledoc """
  Protocol for a single composable data transformation step.

  Any value that implements this protocol can participate in a transform
  pipeline. Returning `{:ok, value}` passes the result to the next step;
  `{:error, reason}` halts the pipeline immediately.
  """

  @spec apply(t(), term()) :: {:ok, term()} | {:error, term()}
  def apply(step, value)
end

defmodule Transform.Pipeline do
  @moduledoc """
  Runs a list of `Transform.Step` implementations sequentially, threading
  the output of each step into the input of the next.
  """

  @spec run([Transform.Step.t()], term()) ::
          {:ok, term()} | {:error, {non_neg_integer(), term()}}
  def run(steps, initial_value) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, initial_value}, fn {step, idx}, {:ok, value} ->
      case Transform.Step.apply(step, value) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, {idx, reason}}}
      end
    end)
  end

  @spec run!([ Transform.Step.t()], term()) :: term()
  def run!(steps, initial_value) do
    case run(steps, initial_value) do
      {:ok, result} -> result
      {:error, {idx, reason}} ->
        raise "Transform.Pipeline failed at step #{idx}: #{inspect(reason)}"
    end
  end
end

defmodule Transform.Steps.MapKeys do
  @moduledoc "Converts all string keys in a map to atoms using a known safe allowlist."

  @type t :: %__MODULE__{allowlist: [atom()]}
  defstruct [:allowlist]

  defimpl Transform.Step do
    def apply(%{allowlist: allowed}, value) when is_map(value) do
      result =
        Map.new(value, fn
          {key, v} when is_binary(key) ->
            atom = Enum.find(allowed, &(Atom.to_string(&1) == key))
            if atom, do: {atom, v}, else: {key, v}
          entry -> entry
        end)
      {:ok, result}
    end
    def apply(_step, value), do: {:ok, value}
  end
end

defmodule Transform.Steps.Compact do
  @moduledoc "Removes nil and empty-string values from a map."

  defstruct []

  defimpl Transform.Step do
    def apply(_step, value) when is_map(value) do
      {:ok, Map.reject(value, fn {_, v} -> v in [nil, ""] end)}
    end
    def apply(_step, value), do: {:ok, value}
  end
end

defmodule Transform.Steps.Validate do
  @moduledoc "Applies a validation predicate, returning an error when it fails."

  @type t :: %__MODULE__{predicate: (term() -> boolean()), reason: term()}
  defstruct [:predicate, :reason]

  defimpl Transform.Step do
    def apply(%{predicate: pred, reason: reason}, value) do
      if pred.(value), do: {:ok, value}, else: {:error, reason}
    end
  end
end

defmodule Transform.Steps.Cast do
  @moduledoc "Applies a mapping function to transform the value."

  @type t :: %__MODULE__{fun: (term() -> term())}
  defstruct [:fun]

  defimpl Transform.Step do
    def apply(%{fun: fun}, value) do
      {:ok, fun.(value)}
    rescue
      error -> {:error, {:cast_failed, error}}
    end
  end
end
```

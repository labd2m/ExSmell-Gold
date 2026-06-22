**File:** `example_good_1401.md`

```elixir
defmodule Experiments.Variant do
  @moduledoc "A named variant within an experiment with its traffic allocation weight."

  @enforce_keys [:name, :weight]
  defstruct [:name, :weight, :metadata]

  @type t :: %__MODULE__{
          name: String.t(),
          weight: pos_integer(),
          metadata: map() | nil
        }

  @spec new(String.t(), pos_integer(), keyword()) :: t()
  def new(name, weight, opts \\ []) when is_binary(name) and is_integer(weight) and weight > 0 do
    %__MODULE__{name: name, weight: weight, metadata: Keyword.get(opts, :metadata)}
  end
end

defmodule Experiments.Experiment do
  @moduledoc "Defines an experiment with its variants and traffic eligibility rules."

  alias Experiments.Variant

  @enforce_keys [:id, :name, :variants]
  defstruct [:id, :name, :variants, :active, :salt, :eligible?]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          variants: [Variant.t()],
          active: boolean(),
          salt: String.t(),
          eligible?: (String.t() -> boolean()) | nil
        }

  @spec new(String.t(), String.t(), [Variant.t()], keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(id, name, variants, opts \\ []) do
    cond do
      variants == [] ->
        {:error, "experiment must have at least one variant"}

      Enum.any?(variants, &(&1.weight <= 0)) ->
        {:error, "all variant weights must be positive"}

      true ->
        {:ok, %__MODULE__{
          id: id,
          name: name,
          variants: variants,
          active: Keyword.get(opts, :active, true),
          salt: Keyword.get(opts, :salt, id),
          eligible?: Keyword.get(opts, :eligible?)
        }}
    end
  end

  @spec total_weight(t()) :: pos_integer()
  def total_weight(%__MODULE__{variants: variants}) do
    Enum.sum(Enum.map(variants, & &1.weight))
  end
end

defmodule Experiments.Bucketer do
  @moduledoc """
  Deterministically assigns a subject to an experiment variant using
  a hash-based bucketing strategy. The same subject always receives
  the same variant for a given experiment and salt.
  """

  alias Experiments.{Experiment, Variant}

  @spec assign(Experiment.t(), String.t()) ::
          {:ok, Variant.t()} | {:error, :experiment_inactive} | {:error, :subject_ineligible}
  def assign(%Experiment{active: false}, _subject_id) do
    {:error, :experiment_inactive}
  end

  def assign(%Experiment{} = experiment, subject_id) when is_binary(subject_id) do
    if eligible?(experiment, subject_id) do
      bucket = compute_bucket(experiment.salt, subject_id)
      variant = select_variant(experiment.variants, bucket)
      {:ok, variant}
    else
      {:error, :subject_ineligible}
    end
  end

  defp eligible?(%Experiment{eligible?: nil}, _subject_id), do: true
  defp eligible?(%Experiment{eligible?: func}, subject_id), do: func.(subject_id)

  defp compute_bucket(salt, subject_id) do
    hash_input = "#{salt}:#{subject_id}"
    <<bucket::unsigned-32, _::binary>> = :crypto.hash(:md5, hash_input)
    rem(bucket, 10_000)
  end

  defp select_variant(variants, bucket) do
    total = variants |> Enum.map(& &1.weight) |> Enum.sum()
    normalized = rem(bucket, total)
    pick_variant(variants, normalized)
  end

  defp pick_variant([last], _remaining), do: last

  defp pick_variant([%Variant{weight: weight} = variant | rest], remaining) do
    if remaining < weight, do: variant, else: pick_variant(rest, remaining - weight)
  end
end

defmodule Experiments do
  @moduledoc "Public interface for querying experiment variant assignments."

  alias Experiments.{Bucketer, Experiment, Variant}

  @spec assigned_variant(Experiment.t(), String.t()) :: {:ok, Variant.t()} | {:error, term()}
  defdelegate assigned_variant(experiment, subject_id), to: Bucketer, as: :assign

  @spec in_variant?(Experiment.t(), String.t(), String.t()) :: boolean()
  def in_variant?(%Experiment{} = experiment, subject_id, variant_name) do
    case Bucketer.assign(experiment, subject_id) do
      {:ok, %Variant{name: ^variant_name}} -> true
      _ -> false
    end
  end
end
```

```elixir
defmodule Onboarding.Wizard do
  @moduledoc """
  A pure functional multi-step onboarding wizard.
  State advances through a fixed sequence of steps. Each step transition
  validates only the fields relevant to that step before progressing.
  """

  @steps [:account, :profile, :billing, :confirmation]

  @type step :: :account | :profile | :billing | :confirmation
  @type field_errors :: %{atom() => list(String.t())}

  @type t :: %__MODULE__{
          step: step(),
          data: map(),
          completed_steps: list(step()),
          errors: field_errors()
        }

  defstruct step: :account, data: %{}, completed_steps: [], errors: %{}

  @spec start() :: t()
  def start, do: %__MODULE__{}

  @spec advance(t(), map()) :: {:ok, t()} | {:error, t()}
  def advance(%__MODULE__{step: step} = wizard, attrs) when is_map(attrs) do
    case validate_step(step, attrs) do
      %{} = errors when map_size(errors) > 0 ->
        {:error, %{wizard | errors: errors}}

      _ ->
        updated_data = Map.merge(wizard.data, attrs)
        next = next_step(step)

        {:ok,
         %{
           wizard
           | step: next,
             data: updated_data,
             completed_steps: [step | wizard.completed_steps],
             errors: %{}
         }}
    end
  end

  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{completed_steps: done}), do: :confirmation in done

  @spec current_step_index(t()) :: non_neg_integer()
  def current_step_index(%__MODULE__{step: step}) do
    Enum.find_index(@steps, &(&1 == step)) || 0
  end

  @spec steps() :: list(step())
  def steps, do: @steps

  defp next_step(:account), do: :profile
  defp next_step(:profile), do: :billing
  defp next_step(:billing), do: :confirmation
  defp next_step(:confirmation), do: :confirmation

  defp validate_step(:account, attrs) do
    %{}
    |> require_string(:email, attrs)
    |> require_string(:password, attrs)
    |> validate_min_length(:password, 8, attrs)
  end

  defp validate_step(:profile, attrs) do
    %{}
    |> require_string(:first_name, attrs)
    |> require_string(:last_name, attrs)
  end

  defp validate_step(:billing, attrs) do
    %{}
    |> require_string(:card_token, attrs)
    |> require_string(:billing_name, attrs)
  end

  defp validate_step(:confirmation, _attrs), do: %{}

  defp require_string(errors, field, attrs) do
    case Map.get(attrs, field) do
      value when is_binary(value) and byte_size(value) > 0 -> errors
      _ -> Map.update(errors, field, ["is required"], &["is required" | &1])
    end
  end

  defp validate_min_length(errors, field, min, attrs) do
    case Map.get(attrs, field) do
      value when is_binary(value) and byte_size(value) >= min -> errors
      _ -> Map.update(errors, field, ["must be at least #{min} characters"], &["must be at least #{min} characters" | &1])
    end
  end
end
```

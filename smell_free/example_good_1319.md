**File:** `example_good_1319.md`

```elixir
defmodule InputCoercion.Field do
  @moduledoc "Describes a single field in an input object schema."

  @enforce_keys [:name, :type]
  defstruct [:name, :type, :required, :default, :validators]

  @type field_type ::
          :string
          | :integer
          | :float
          | :boolean
          | :date
          | :datetime
          | {:list, field_type()}
          | {:object, [t()]}

  @type t :: %__MODULE__{
          name: atom(),
          type: field_type(),
          required: boolean(),
          default: term(),
          validators: [(term() -> :ok | {:error, String.t()})]
        }

  @spec new(atom(), field_type(), keyword()) :: t()
  def new(name, type, opts \\ []) do
    %__MODULE__{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default),
      validators: Keyword.get(opts, :validators, [])
    }
  end
end

defmodule InputCoercion.Coercer do
  @moduledoc """
  Coerces and validates raw input maps against a list of field definitions.
  Returns a typed map on success or a list of per-field errors on failure.
  """

  alias InputCoercion.Field

  @type coerce_result :: {:ok, map()} | {:error, %{atom() => [String.t()]}}

  @spec coerce(map(), [Field.t()]) :: coerce_result()
  def coerce(input, fields) when is_map(input) and is_list(fields) do
    {values, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn field, {vals, errs} ->
        raw = Map.get(input, field.name) || Map.get(input, to_string(field.name))

        case process_field(raw, field) do
          {:ok, value} -> {Map.put(vals, field.name, value), errs}
          {:error, messages} -> {vals, Map.put(errs, field.name, messages)}
        end
      end)

    if map_size(errors) == 0, do: {:ok, values}, else: {:error, errors}
  end

  defp process_field(nil, %Field{required: true}) do
    {:error, ["is required"]}
  end

  defp process_field(nil, %Field{default: default}) do
    {:ok, default}
  end

  defp process_field(raw, %Field{type: type, validators: validators}) do
    with {:ok, coerced} <- coerce_type(raw, type),
         :ok <- run_validators(coerced, validators) do
      {:ok, coerced}
    end
  end

  defp coerce_type(val, :string) when is_binary(val), do: {:ok, val}
  defp coerce_type(val, :string), do: {:error, ["must be a string"]}

  defp coerce_type(val, :integer) when is_integer(val), do: {:ok, val}
  defp coerce_type(val, :integer) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> {:ok, n}
      _ -> {:error, ["must be an integer"]}
    end
  end

  defp coerce_type(_, :integer), do: {:error, ["must be an integer"]}

  defp coerce_type(val, :float) when is_float(val), do: {:ok, val}
  defp coerce_type(val, :float) when is_integer(val), do: {:ok, val / 1}
  defp coerce_type(_, :float), do: {:error, ["must be a number"]}

  defp coerce_type(val, :boolean) when is_boolean(val), do: {:ok, val}
  defp coerce_type("true", :boolean), do: {:ok, true}
  defp coerce_type("false", :boolean), do: {:ok, false}
  defp coerce_type(_, :boolean), do: {:error, ["must be a boolean"]}

  defp coerce_type(val, :date) when is_binary(val) do
    case Date.from_iso8601(val) do
      {:ok, d} -> {:ok, d}
      _ -> {:error, ["must be a date in YYYY-MM-DD format"]}
    end
  end

  defp coerce_type(_, :date), do: {:error, ["must be a date string"]}

  defp coerce_type(val, :datetime) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, ["must be an ISO 8601 datetime string"]}
    end
  end

  defp coerce_type(_, :datetime), do: {:error, ["must be a datetime string"]}

  defp coerce_type(val, {:list, item_type}) when is_list(val) do
    results = Enum.map(val, &coerce_type(&1, item_type))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, v} -> v end)}
    else
      {:error, ["contains invalid items"]}
    end
  end

  defp coerce_type(_, {:list, _}), do: {:error, ["must be a list"]}

  defp coerce_type(val, {:object, nested_fields}) when is_map(val) do
    case InputCoercion.Coercer.coerce(val, nested_fields) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, ["contains invalid nested fields"]}
    end
  end

  defp coerce_type(_, {:object, _}), do: {:error, ["must be an object"]}

  defp run_validators(value, validators) do
    errors = Enum.flat_map(validators, fn v ->
      case v.(value) do
        :ok -> []
        {:error, msg} -> [msg]
      end
    end)

    if errors == [], do: :ok, else: {:error, errors}
  end
end
```

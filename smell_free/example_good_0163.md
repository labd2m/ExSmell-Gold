```elixir
defmodule Config.FieldSpec do
  @moduledoc false

  @type field_type :: :string | :integer | :boolean | :url | :non_empty_string

  @type t :: %__MODULE__{
          key: atom(),
          type: field_type(),
          required: boolean(),
          default: term()
        }

  defstruct [:key, :type, required: true, default: nil]

  @spec new(atom(), field_type(), keyword()) :: t()
  def new(key, type, opts \\ []) when is_atom(key) do
    %__MODULE__{
      key: key,
      type: type,
      required: Keyword.get(opts, :required, true),
      default: Keyword.get(opts, :default)
    }
  end
end

defmodule Config.Validator do
  @moduledoc """
  Validates a keyword list of runtime configuration values against a
  declared set of typed field specifications.

  All violations are collected before returning so operators receive a
  complete picture of misconfiguration rather than fixing one error at
  a time. Missing required fields and type mismatches are surfaced with
  human-readable descriptions suitable for startup logs.
  """

  alias Config.FieldSpec

  @type validation_error :: {atom(), String.t()}
  @type validated_config :: keyword()

  @spec validate(keyword(), [FieldSpec.t()]) ::
          {:ok, validated_config()} | {:error, [validation_error()]}
  def validate(raw_config, specs) when is_list(raw_config) and is_list(specs) do
    {config, errors} =
      Enum.reduce(specs, {[], []}, fn spec, {acc_config, acc_errors} ->
        case resolve_field(raw_config, spec) do
          {:ok, key, value} -> {[{key, value} | acc_config], acc_errors}
          {:error, error} -> {acc_config, [error | acc_errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(config)}
      violations -> {:error, Enum.reverse(violations)}
    end
  end

  defp resolve_field(raw_config, %FieldSpec{key: key, required: required, default: default} = spec) do
    case Keyword.fetch(raw_config, key) do
      {:ok, value} -> coerce_and_validate(key, value, spec.type)
      :error when required and is_nil(default) -> {:error, {key, "is required but was not set"}}
      :error -> {:ok, key, default}
    end
  end

  defp coerce_and_validate(key, value, :string) when is_binary(value), do: {:ok, key, value}
  defp coerce_and_validate(key, value, :string) when is_integer(value), do: {:ok, key, Integer.to_string(value)}
  defp coerce_and_validate(key, _value, :string), do: {:error, {key, "must be a string"}}

  defp coerce_and_validate(key, value, :non_empty_string) when is_binary(value) and value != "" do
    {:ok, key, value}
  end

  defp coerce_and_validate(key, _value, :non_empty_string) do
    {:error, {key, "must be a non-empty string"}}
  end

  defp coerce_and_validate(key, value, :integer) when is_integer(value), do: {:ok, key, value}

  defp coerce_and_validate(key, value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, key, int}
      _ -> {:error, {key, "must be an integer"}}
    end
  end

  defp coerce_and_validate(key, _value, :integer), do: {:error, {key, "must be an integer"}}

  defp coerce_and_validate(key, value, :boolean) when is_boolean(value), do: {:ok, key, value}
  defp coerce_and_validate(key, "true", :boolean), do: {:ok, key, true}
  defp coerce_and_validate(key, "false", :boolean), do: {:ok, key, false}
  defp coerce_and_validate(key, _value, :boolean), do: {:error, {key, "must be true or false"}}

  defp coerce_and_validate(key, value, :url) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) ->
        {:ok, key, value}

      _ ->
        {:error, {key, "must be a valid HTTP or HTTPS URL"}}
    end
  end

  defp coerce_and_validate(key, _value, :url), do: {:error, {key, "must be a URL string"}}
end
```

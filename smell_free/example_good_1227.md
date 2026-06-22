```elixir
defmodule Config.Schema do
  @moduledoc """
  Declares the expected shape and constraints for application configuration.
  Validation runs at application startup to surface misconfigurations early
  rather than allowing them to cause opaque runtime failures.
  """

  @type field_spec :: %{
          required: boolean(),
          type: atom(),
          default: term() | :no_default,
          allowed: list(term()) | :any
        }

  @spec fields() :: %{atom() => field_spec()}
  def fields do
    %{
      database_url: %{required: true, type: :string, default: :no_default, allowed: :any},
      pool_size: %{required: false, type: :integer, default: 10, allowed: :any},
      secret_key_base: %{required: true, type: :string, default: :no_default, allowed: :any},
      log_level: %{required: false, type: :atom, default: :info, allowed: [:debug, :info, :warning, :error]},
      mailer_adapter: %{required: false, type: :atom, default: :smtp, allowed: [:smtp, :sendgrid, :local]},
      max_upload_bytes: %{required: false, type: :integer, default: 10_485_760, allowed: :any},
      cdn_base_url: %{required: false, type: :string, default: :no_default, allowed: :any}
    }
  end
end

defmodule Config.Validator do
  @moduledoc """
  Validates a raw configuration map against a declared schema.
  Missing required fields, type mismatches, and disallowed values are all
  reported as a list of structured errors rather than failing on the first issue.
  """

  alias Config.Schema

  @type config_map :: %{atom() => term()}
  @type field_error :: %{field: atom(), message: String.t()}
  @type validation_result :: {:ok, config_map()} | {:error, list(field_error())}

  @spec validate(config_map()) :: validation_result()
  def validate(config) when is_map(config) do
    errors =
      Schema.fields()
      |> Enum.flat_map(fn {field, spec} -> check_field(config, field, spec) end)

    if Enum.empty?(errors) do
      {:ok, apply_defaults(config)}
    else
      {:error, errors}
    end
  end

  @spec apply_defaults(config_map()) :: config_map()
  def apply_defaults(config) when is_map(config) do
    Enum.reduce(Schema.fields(), config, fn {field, spec}, acc ->
      if Map.has_key?(acc, field) or spec.default == :no_default do
        acc
      else
        Map.put(acc, field, spec.default)
      end
    end)
  end

  defp check_field(config, field, spec) do
    case Map.fetch(config, field) do
      :error -> check_required(field, spec)
      {:ok, value} -> check_value(field, value, spec)
    end
  end

  defp check_required(_field, %{required: false}), do: []

  defp check_required(field, %{required: true}) do
    [%{field: field, message: "is required but was not provided"}]
  end

  defp check_value(field, value, spec) do
    []
    |> check_type(field, value, spec.type)
    |> check_allowed(field, value, spec.allowed)
  end

  defp check_type(errors, _field, value, :string) when is_binary(value), do: errors
  defp check_type(errors, _field, value, :integer) when is_integer(value), do: errors
  defp check_type(errors, _field, value, :atom) when is_atom(value), do: errors
  defp check_type(errors, _field, value, :boolean) when is_boolean(value), do: errors

  defp check_type(errors, field, _value, expected_type) do
    [%{field: field, message: "must be of type #{expected_type}"} | errors]
  end

  defp check_allowed(errors, _field, _value, :any), do: errors

  defp check_allowed(errors, field, value, allowed) when is_list(allowed) do
    if value in allowed do
      errors
    else
      formatted = allowed |> Enum.map(&inspect/1) |> Enum.join(", ")
      [%{field: field, message: "must be one of: #{formatted}"} | errors]
    end
  end
end

defmodule Config.Loader do
  @moduledoc """
  Loads application configuration from the environment, validates it against
  the schema, and raises at startup if the configuration is invalid.
  """

  alias Config.Validator

  @spec load!() :: Validator.config_map()
  def load! do
    config = %{
      database_url: System.get_env("DATABASE_URL"),
      pool_size: parse_integer(System.get_env("POOL_SIZE")),
      secret_key_base: System.get_env("SECRET_KEY_BASE"),
      log_level: parse_atom(System.get_env("LOG_LEVEL")),
      mailer_adapter: parse_atom(System.get_env("MAILER_ADAPTER")),
      max_upload_bytes: parse_integer(System.get_env("MAX_UPLOAD_BYTES")),
      cdn_base_url: System.get_env("CDN_BASE_URL")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()

    case Validator.validate(config) do
      {:ok, validated} -> validated
      {:error, errors} -> raise format_errors(errors)
    end
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_atom(nil), do: nil
  defp parse_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp format_errors(errors) do
    lines = Enum.map(errors, fn %{field: f, message: m} -> "  - #{f}: #{m}" end)
    "Invalid application configuration:\n" <> Enum.join(lines, "\n")
  end
end
```

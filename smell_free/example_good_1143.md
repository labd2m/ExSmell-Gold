```elixir
defmodule Appconf.Loader do
  @moduledoc """
  Validates and loads typed application configuration at runtime from
  the environment. All values are coerced to their declared types and
  validated against constraints before being returned as a structured map.
  Failures surface as descriptive error lists rather than runtime crashes.
  """

  @type field_type :: :string | :integer | :boolean | :url | :non_neg_integer | :pos_integer
  @type field_def :: {atom(), field_type(), required: boolean(), default: term()}
  @type config_map :: %{atom() => term()}

  @spec load([field_def()], map()) :: {:ok, config_map()} | {:error, [String.t()]}
  def load(field_defs, source \\ System.get_env()) when is_list(field_defs) and is_map(source) do
    {values, errors} =
      Enum.reduce(field_defs, {%{}, []}, fn {key, type, opts}, {acc, errs} ->
        env_key = key |> Atom.to_string() |> String.upcase()
        raw = Map.get(source, env_key)
        required = Keyword.get(opts, :required, false)
        default = Keyword.get(opts, :default, nil)

        case resolve_value(raw, type, required, default, env_key) do
          {:ok, value} -> {Map.put(acc, key, value), errs}
          {:error, msg} -> {acc, [msg | errs]}
        end
      end)

    if Enum.empty?(errors) do
      {:ok, values}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @spec resolve_value(String.t() | nil, field_type(), boolean(), term(), String.t()) ::
          {:ok, term()} | {:error, String.t()}
  defp resolve_value(nil, _type, true, _default, key) do
    {:error, "#{key} is required but not set"}
  end

  defp resolve_value(nil, _type, false, default, _key) do
    {:ok, default}
  end

  defp resolve_value(raw, type, _required, _default, key) do
    coerce(raw, type, key)
  end

  @spec coerce(String.t(), field_type(), String.t()) :: {:ok, term()} | {:error, String.t()}
  defp coerce(raw, :string, _key), do: {:ok, String.trim(raw)}

  defp coerce(raw, :integer, key) do
    case Integer.parse(String.trim(raw)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "#{key} must be an integer, got: #{inspect(raw)}"}
    end
  end

  defp coerce(raw, :non_neg_integer, key) do
    with {:ok, int} <- coerce(raw, :integer, key) do
      if int >= 0 do
        {:ok, int}
      else
        {:error, "#{key} must be a non-negative integer, got: #{int}"}
      end
    end
  end

  defp coerce(raw, :pos_integer, key) do
    with {:ok, int} <- coerce(raw, :integer, key) do
      if int > 0 do
        {:ok, int}
      else
        {:error, "#{key} must be a positive integer, got: #{int}"}
      end
    end
  end

  defp coerce(raw, :boolean, key) do
    case String.downcase(String.trim(raw)) do
      v when v in ~w(true 1 yes on) -> {:ok, true}
      v when v in ~w(false 0 no off) -> {:ok, false}
      _ -> {:error, "#{key} must be a boolean (true/false/1/0), got: #{inspect(raw)}"}
    end
  end

  defp coerce(raw, :url, key) do
    trimmed = String.trim(raw)

    if String.starts_with?(trimmed, ["http://", "https://"]) do
      {:ok, trimmed}
    else
      {:error, "#{key} must be a valid HTTP/HTTPS URL, got: #{inspect(trimmed)}"}
    end
  end
end

defmodule Appconf.DatabaseConfig do
  @moduledoc """
  Typed configuration schema for the primary database connection pool.
  Loads from environment variables with sensible defaults for optional fields.
  """

  alias Appconf.Loader

  @type t :: %{
          database_url: String.t(),
          pool_size: pos_integer(),
          pool_timeout_ms: pos_integer(),
          ssl_enabled: boolean(),
          statement_timeout_ms: non_neg_integer()
        }

  @field_defs [
    {:database_url, :url, required: true, default: nil},
    {:pool_size, :pos_integer, required: false, default: 10},
    {:pool_timeout_ms, :pos_integer, required: false, default: 5_000},
    {:ssl_enabled, :boolean, required: false, default: false},
    {:statement_timeout_ms, :non_neg_integer, required: false, default: 30_000}
  ]

  @spec load() :: {:ok, t()} | {:error, [String.t()]}
  def load do
    Loader.load(@field_defs)
  end

  @spec load!(map()) :: t()
  def load!(source \\ System.get_env()) do
    case Loader.load(@field_defs, source) do
      {:ok, config} ->
        config

      {:error, errors} ->
        raise "Database configuration invalid:\n" <> Enum.join(errors, "\n")
    end
  end
end

defmodule Appconf.EmailConfig do
  @moduledoc """
  Typed configuration schema for the transactional email provider.
  """

  alias Appconf.Loader

  @type t :: %{
          smtp_host: String.t(),
          smtp_port: pos_integer(),
          smtp_username: String.t(),
          smtp_password: String.t(),
          sender_address: String.t(),
          tls_enabled: boolean()
        }

  @field_defs [
    {:smtp_host, :string, required: true, default: nil},
    {:smtp_port, :pos_integer, required: false, default: 587},
    {:smtp_username, :string, required: true, default: nil},
    {:smtp_password, :string, required: true, default: nil},
    {:sender_address, :string, required: true, default: nil},
    {:tls_enabled, :boolean, required: false, default: true}
  ]

  @spec load() :: {:ok, t()} | {:error, [String.t()]}
  def load do
    Loader.load(@field_defs)
  end
end
```

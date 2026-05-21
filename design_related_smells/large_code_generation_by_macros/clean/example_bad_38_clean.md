```elixir
defmodule MyApp.Config.AccessorDSL do
  @moduledoc """
  DSL for declaring typed, validated application config keys.

  Example:

      defmodule MyApp.Config do
        use MyApp.Config.AccessorDSL, otp_app: :my_app

        config_key :database_url,
          type:     :string,
          required: true,
          doc:      "PostgreSQL connection URL"

        config_key :pool_size,
          type:     :integer,
          default:  10,
          min:      1,
          max:      100,
          doc:      "Ecto repo pool size"

        config_key :log_level,
          type:    :atom,
          default: :info,
          allowed: [:debug, :info, :warning, :error],
          doc:     "Logger level"

        config_key :feature_timeout_ms,
          type:        :integer,
          default:     5_000,
          env_var:     "FEATURE_TIMEOUT_MS",
          doc:         "Timeout for feature API calls"
      end
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      import MyApp.Config.AccessorDSL, only: [config_key: 2]
      Module.register_attribute(__MODULE__, :config_keys, accumulate: true)
      @otp_app unquote(otp_app)
      @before_compile MyApp.Config.AccessorDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def config_keys, do: @config_keys
      def otp_app,     do: @otp_app
    end
  end

  defmacro config_key(key, opts) do
    quote do
      key  = unquote(key)
      opts = unquote(opts)

      unless is_atom(key) do
        raise ArgumentError,
              "config_key/2: key must be an atom, got #{inspect(key)}"
      end

      valid_types = [:string, :integer, :float, :boolean, :atom, :list, :map]
      type = Keyword.get(opts, :type, :string)

      unless type in valid_types do
        raise ArgumentError,
              "config_key/2: :type must be one of #{inspect(valid_types)}, " <>
                "got #{inspect(type)}"
      end

      required = Keyword.get(opts, :required, false)

      unless is_boolean(required) do
        raise ArgumentError,
              "config_key/2: :required must be a boolean, got #{inspect(required)}"
      end

      default = Keyword.get(opts, :default)

      if not is_nil(default) and required do
        raise ArgumentError,
              "config_key/2: #{inspect(key)} cannot have both :required true and a :default"
      end

      allowed = Keyword.get(opts, :allowed)

      if not is_nil(allowed) do
        unless is_list(allowed) and length(allowed) > 0 do
          raise ArgumentError,
                "config_key/2: :allowed must be a non-empty list, got #{inspect(allowed)}"
        end

        if not is_nil(default) and default not in allowed do
          raise ArgumentError,
                "config_key/2: default #{inspect(default)} is not in :allowed #{inspect(allowed)}"
        end
      end

      min_val = Keyword.get(opts, :min)
      max_val = Keyword.get(opts, :max)

      if not is_nil(min_val) and type not in [:integer, :float] do
        raise ArgumentError,
              "config_key/2: :min is only valid for :integer or :float keys"
      end

      if not is_nil(max_val) and type not in [:integer, :float] do
        raise ArgumentError,
              "config_key/2: :max is only valid for :integer or :float keys"
      end

      env_var = Keyword.get(opts, :env_var)

      if not is_nil(env_var) and not is_binary(env_var) do
        raise ArgumentError,
              "config_key/2: :env_var must be a string env variable name, got #{inspect(env_var)}"
      end

      doc = Keyword.get(opts, :doc, "")

      unless is_binary(doc) do
        raise ArgumentError,
              "config_key/2: :doc must be a string, got #{inspect(doc)}"
      end

      existing = Module.get_attribute(__MODULE__, :config_keys)

      if Enum.any?(existing, fn k -> k.key == key end) do
        raise ArgumentError,
              "config_key/2: duplicate config key #{inspect(key)} in #{inspect(__MODULE__)}"
      end

      entry = %{
        key:      key,
        type:     type,
        required: required,
        default:  default,
        allowed:  allowed,
        min:      min_val,
        max:      max_val,
        env_var:  env_var,
        doc:      doc
      }

      @config_keys entry

      def unquote(key)() do
        MyApp.Config.AccessorDSL.fetch_value(__MODULE__, unquote(key))
      end
    end
  end

  @doc false
  def fetch_value(config_module, key) do
    otp_app = config_module.otp_app()
    spec    = Enum.find(config_module.config_keys(), fn k -> k.key == key end)

    raw =
      if spec.env_var do
        System.get_env(spec.env_var) || Application.get_env(otp_app, key, spec.default)
      else
        Application.get_env(otp_app, key, spec.default)
      end

    cond do
      is_nil(raw) and spec.required ->
        raise "Required config #{inspect(key)} is not set for #{inspect(otp_app)}"

      is_nil(raw) ->
        nil

      true ->
        coerce(raw, spec.type)
    end
  end

  defp coerce(value, :integer) when is_binary(value), do: String.to_integer(value)
  defp coerce(value, :float)   when is_binary(value), do: String.to_float(value)
  defp coerce(value, :atom)    when is_binary(value), do: String.to_existing_atom(value)
  defp coerce(value, _type),                          do: value
end
```

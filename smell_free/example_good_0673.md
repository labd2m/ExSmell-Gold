```elixir
defmodule Config.Schema do
  @moduledoc """
  Macro DSL for declaring typed, validated configuration schemas.

  Modules that `use Config.Schema` gain a `field/3` macro for declaring
  typed configuration fields and a `validate/1` function generated at
  compile time. Calling `validate/1` with a keyword list returns either
  `{:ok, validated_map}` or `{:error, [errors]}` without any runtime
  reflection over the module source.
  """

  defmacro __using__(_opts) do
    quote do
      import Config.Schema, only: [field: 2, field: 3]
      Module.register_attribute(__MODULE__, :config_fields, accumulate: true)
      @before_compile Config.Schema
    end
  end

  defmacro field(name, type, opts \\ []) do
    quote do
      @config_fields {unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :config_fields) |> Enum.reverse()

    quote do
      @field_specs unquote(Macro.escape(fields))

      @spec validate(keyword()) :: {:ok, map()} | {:error, [String.t()]}
      def validate(config) when is_list(config) do
        Config.Schema.Validator.run(config, @field_specs)
      end

      @spec field_specs() :: list()
      def field_specs, do: @field_specs
    end
  end
end

defmodule Config.Schema.Validator do
  @moduledoc false

  @spec run(keyword(), list()) :: {:ok, map()} | {:error, [String.t()]}
  def run(config, specs) do
    {result, errors} =
      Enum.reduce(specs, {%{}, []}, fn {name, type, opts}, {acc, errs} ->
        required = Keyword.get(opts, :required, true)
        default = Keyword.get(opts, :default, nil)

        case Keyword.fetch(config, name) do
          {:ok, raw} ->
            case coerce(raw, type) do
              {:ok, value} -> {Map.put(acc, name, value), errs}
              {:error, msg} -> {acc, ["#{name}: #{msg}" | errs]}
            end

          :error when required and is_nil(default) ->
            {acc, ["#{name}: is required" | errs]}

          :error ->
            {Map.put(acc, name, default), errs}
        end
      end)

    if errors == [], do: {:ok, result}, else: {:error, Enum.reverse(errors)}
  end

  defp coerce(v, :string) when is_binary(v), do: {:ok, v}
  defp coerce(v, :string) when is_integer(v), do: {:ok, Integer.to_string(v)}
  defp coerce(_, :string), do: {:error, "must be a string"}
  defp coerce(v, :integer) when is_integer(v), do: {:ok, v}
  defp coerce(v, :integer) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end
  defp coerce(_, :integer), do: {:error, "must be an integer"}
  defp coerce(v, :boolean) when is_boolean(v), do: {:ok, v}
  defp coerce("true", :boolean), do: {:ok, true}
  defp coerce("false", :boolean), do: {:ok, false}
  defp coerce(_, :boolean), do: {:error, "must be a boolean"}
  defp coerce(v, :atom) when is_atom(v), do: {:ok, v}
  defp coerce(_, :atom), do: {:error, "must be an atom"}
  defp coerce(v, {:one_of, choices}) do
    if v in choices, do: {:ok, v}, else: {:error, "must be one of #{inspect(choices)}"}
  end
end

defmodule MyApp.DatabaseConfig do
  @moduledoc false

  use Config.Schema

  field :host, :string, default: "localhost"
  field :port, :integer, default: 5432
  field :database, :string
  field :pool_size, :integer, default: 10
  field :ssl, :boolean, default: false
  field :log_level, {:one_of, [:debug, :info, :warning, :error]}, default: :warning
end
```

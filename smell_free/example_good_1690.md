```elixir
defmodule Config.TypedDsl do
  @moduledoc """
  A macro-based DSL that lets adapter modules declare their configuration
  schema inline. At compile time the declarations are accumulated and a
  typed `load/1` function is generated that validates and coerces values.
  """

  defmacro __using__(_opts) do
    quote do
      import Config.TypedDsl, only: [config_field: 2, config_field: 3]
      Module.register_attribute(__MODULE__, :config_fields, accumulate: true)
      @before_compile Config.TypedDsl
    end
  end

  defmacro config_field(name, type, opts \\ []) do
    quote do
      @config_fields {unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :config_fields) |> Enum.reverse()

    quote do
      @spec load(keyword()) :: {:ok, map()} | {:error, [{atom(), atom()}]}
      def load(opts) when is_list(opts) do
        Config.TypedDsl.Runtime.load(unquote(fields), opts)
      end

      @spec load!(keyword()) :: map()
      def load!(opts) do
        case load(opts) do
          {:ok, config} -> config
          {:error, errors} ->
            msg = Enum.map_join(errors, ", ", fn {k, r} -> "#{k}: #{r}" end)
            raise ArgumentError, "Config validation failed: #{msg}"
        end
      end

      @spec field_specs() :: [{atom(), atom(), keyword()}]
      def field_specs, do: unquote(fields)
    end
  end
end

defmodule Config.TypedDsl.Runtime do
  @moduledoc false

  @spec load([{atom(), atom(), keyword()}], keyword()) :: {:ok, map()} | {:error, list()}
  def load(fields, opts) do
    {values, errors} =
      Enum.reduce(fields, {%{}, []}, fn {name, type, field_opts}, {acc_vals, acc_errs} ->
        raw = Keyword.get(opts, name)
        required = Keyword.get(field_opts, :required, false)
        default = Keyword.get(field_opts, :default, nil)

        cond do
          is_nil(raw) and required ->
            {acc_vals, [{name, :required} | acc_errs]}

          is_nil(raw) ->
            {Map.put(acc_vals, name, default), acc_errs}

          true ->
            case coerce(raw, type) do
              {:ok, value} -> {Map.put(acc_vals, name, value), acc_errs}
              {:error, reason} -> {acc_vals, [{name, reason} | acc_errs]}
            end
        end
      end)

    case errors do
      [] -> {:ok, values}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @spec coerce(term(), atom()) :: {:ok, term()} | {:error, atom()}
  defp coerce(v, :string) when is_binary(v), do: {:ok, v}
  defp coerce(v, :string) when is_atom(v), do: {:ok, to_string(v)}
  defp coerce(_, :string), do: {:error, :not_a_string}

  defp coerce(v, :integer) when is_integer(v), do: {:ok, v}
  defp coerce(v, :integer) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :not_an_integer}
    end
  end
  defp coerce(_, :integer), do: {:error, :not_an_integer}

  defp coerce(v, :boolean) when is_boolean(v), do: {:ok, v}
  defp coerce("true", :boolean), do: {:ok, true}
  defp coerce("false", :boolean), do: {:ok, false}
  defp coerce(_, :boolean), do: {:error, :not_a_boolean}

  defp coerce(v, :atom) when is_atom(v), do: {:ok, v}
  defp coerce(v, :atom) when is_binary(v) do
    {:ok, String.to_existing_atom(v)}
  rescue
    ArgumentError -> {:error, :unknown_atom}
  end

  defp coerce(v, :uri) when is_binary(v) do
    uri = URI.parse(v)
    if is_binary(uri.scheme) and is_binary(uri.host), do: {:ok, uri}, else: {:error, :invalid_uri}
  end
  defp coerce(_, :uri), do: {:error, :invalid_uri}

  defp coerce(v, _unknown_type), do: {:ok, v}
end
```

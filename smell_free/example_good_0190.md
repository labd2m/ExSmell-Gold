```elixir
defmodule Platform.ConfigValidator do
  @moduledoc """
  Validates required application configuration at startup, producing clear
  error messages for missing or malformed values before any supervised
  process tree is started.

  Call `validate!/1` from your `Application.start/2` callback to fail fast
  and prevent silent misconfiguration in any environment.
  """

  @type key_path :: [atom()]
  @type rule :: (term() -> :ok | {:error, String.t()})
  @type spec :: %{path: key_path(), rule: rule()}

  @doc """
  Validates all specs in `schema` against the current application environment.
  Raises `RuntimeError` with a formatted message on the first failure.
  """
  @spec validate!(atom(), [spec()]) :: :ok
  def validate!(app, schema) when is_atom(app) and is_list(schema) do
    errors = Enum.flat_map(schema, &check_spec(app, &1))

    if errors != [] do
      formatted = Enum.map_join(errors, "\n", fn {path, msg} ->
        "  [#{Enum.join(path, ".")}] #{msg}"
      end)

      raise RuntimeError, """
      Application configuration errors for #{inspect(app)}:
      #{formatted}
      """
    end

    :ok
  end

  @doc "Returns a rule that checks the value is a non-empty string."
  @spec required_string() :: rule()
  def required_string do
    fn
      value when is_binary(value) and byte_size(value) > 0 -> :ok
      nil -> {:error, "is required"}
      "" -> {:error, "must not be empty"}
      other -> {:error, "must be a string, got: #{inspect(other)}"}
    end
  end

  @doc "Returns a rule that checks the value is a positive integer."
  @spec positive_integer() :: rule()
  def positive_integer do
    fn
      value when is_integer(value) and value > 0 -> :ok
      nil -> {:error, "is required"}
      other -> {:error, "must be a positive integer, got: #{inspect(other)}"}
    end
  end

  @doc "Returns a rule that checks the value is one of `allowed_values`."
  @spec one_of([term()]) :: rule()
  def one_of(allowed_values) when is_list(allowed_values) do
    fn
      value ->
        if value in allowed_values do
          :ok
        else
          {:error, "must be one of #{inspect(allowed_values)}, got: #{inspect(value)}"}
        end
    end
  end

  @doc "Returns a rule that checks the value is a valid URL string."
  @spec valid_url() :: rule()
  def valid_url do
    fn
      value when is_binary(value) ->
        case URI.parse(value) do
          %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) -> :ok
          _ -> {:error, "must be a valid http or https URL, got: #{inspect(value)}"}
        end

      other ->
        {:error, "must be a URL string, got: #{inspect(other)}"}
    end
  end

  @doc "Returns a rule that passes only when the value is a non-empty list."
  @spec non_empty_list() :: rule()
  def non_empty_list do
    fn
      [_ | _] -> :ok
      [] -> {:error, "must not be an empty list"}
      nil -> {:error, "is required"}
      other -> {:error, "must be a list, got: #{inspect(other)}"}
    end
  end

  defp check_spec(app, %{path: path, rule: rule}) do
    value = get_nested(app, path)

    case rule.(value) do
      :ok -> []
      {:error, message} -> [{path, message}]
    end
  end

  defp get_nested(app, [key]) do
    Application.get_env(app, key)
  end

  defp get_nested(app, [key | rest]) do
    app
    |> Application.get_env(key, [])
    |> get_in(rest)
  end
end
```

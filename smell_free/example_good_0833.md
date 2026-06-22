```elixir
defmodule MyAppWeb.Plug.ValidateParams do
  @moduledoc """
  A Plug that validates request parameters against a declarative schema before
  the request reaches a controller. Each schema entry declares the parameter
  name, its source (`:query`, `:path`, or `:body`), its type, and whether it
  is required. Coerced values are written to `conn.assigns[:validated_params]`
  so controllers never touch raw strings. Invalid requests receive a structured
  `422` response with per-field error messages.

  ## Usage

      plug MyAppWeb.Plug.ValidateParams, schema: [
        %{name: :page, source: :query, type: :integer, required: false, default: 1},
        %{name: :user_id, source: :path, type: :uuid, required: true}
      ]
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :schema)

  @impl Plug
  def call(conn, schema) do
    {validated, errors} = validate_all(conn, schema)

    if errors == [] do
      assign(conn, :validated_params, validated)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(422, Jason.encode!(%{errors: errors}))
      |> halt()
    end
  end

  # ---------------------------------------------------------------------------
  # Validation engine
  # ---------------------------------------------------------------------------

  defp validate_all(conn, schema) do
    Enum.reduce(schema, {%{}, []}, fn spec, {ok_acc, err_acc} ->
      case validate_param(conn, spec) do
        {:ok, value} ->
          {Map.put(ok_acc, spec.name, value), err_acc}

        {:error, message} ->
          {ok_acc, [%{field: spec.name, message: message} | err_acc]}
      end
    end)
  end

  defp validate_param(conn, spec) do
    raw = extract_raw(conn, spec.source, to_string(spec.name))

    case {raw, Map.get(spec, :required, true)} do
      {nil, true} ->
        {:error, "is required"}

      {nil, false} ->
        {:ok, Map.get(spec, :default)}

      {raw_value, _} ->
        coerce(raw_value, spec.type)
    end
  end

  defp extract_raw(conn, :query, name), do: conn.query_params[name]
  defp extract_raw(conn, :path, name), do: conn.path_params[name]

  defp extract_raw(conn, :body, name) do
    case conn.body_params do
      %{^name => value} -> value
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Type coercions
  # ---------------------------------------------------------------------------

  defp coerce(raw, :string) when is_binary(raw) and byte_size(raw) > 0, do: {:ok, raw}
  defp coerce("", :string), do: {:error, "must not be blank"}
  defp coerce(_, :string), do: {:error, "must be a string"}

  defp coerce(raw, :integer) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce(raw, :integer) when is_integer(raw), do: {:ok, raw}
  defp coerce(_, :integer), do: {:error, "must be an integer"}

  defp coerce(raw, :float) when is_binary(raw) do
    case Float.parse(raw) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "must be a number"}
    end
  end

  defp coerce(raw, :float) when is_number(raw), do: {:ok, raw * 1.0}
  defp coerce(_, :float), do: {:error, "must be a number"}

  defp coerce("true", :boolean), do: {:ok, true}
  defp coerce("false", :boolean), do: {:ok, false}
  defp coerce(raw, :boolean) when is_boolean(raw), do: {:ok, raw}
  defp coerce(_, :boolean), do: {:error, "must be true or false"}

  defp coerce(raw, :uuid) when is_binary(raw) do
    if Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, raw) do
      {:ok, String.downcase(raw)}
    else
      {:error, "must be a valid UUID"}
    end
  end

  defp coerce(_, :uuid), do: {:error, "must be a valid UUID"}

  defp coerce(raw, :date) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "must be a valid ISO 8601 date (YYYY-MM-DD)"}
    end
  end

  defp coerce(raw, :datetime) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, "must be a valid ISO 8601 datetime"}
    end
  end

  defp coerce(raw, {:enum, values}) when is_binary(raw) do
    try do
      atom = String.to_existing_atom(raw)
      if atom in values, do: {:ok, atom}, else: {:error, "must be one of #{inspect(values)}"}
    rescue
      ArgumentError -> {:error, "must be one of #{inspect(values)}"}
    end
  end
end
```

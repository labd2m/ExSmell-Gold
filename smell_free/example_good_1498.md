```elixir
defmodule Localization.Translations.Loader do
  @moduledoc """
  Loads and caches locale translation files from disk.
  Supports dynamic locale switching without application restarts.
  """

  use GenServer

  @type locale :: String.t()
  @type translations :: %{String.t() => String.t()}
  @type state :: %{translations: %{locale() => translations()}, base_dir: String.t()}

  @doc """
  Starts the Loader linked to the calling process.

  ## Options
    - `:base_dir` - filesystem directory containing `{locale}.json` files (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the translation for `key` in `locale`.
  Falls back to `default` if the key is not found.
  """
  @spec translate(locale(), String.t(), String.t()) :: String.t()
  def translate(locale, key, default \\ key)
      when is_binary(locale) and is_binary(key) do
    GenServer.call(__MODULE__, {:translate, locale, key, default})
  end

  @doc """
  Reloads translations for the given locale from disk.
  """
  @spec reload_locale(locale()) :: :ok | {:error, String.t()}
  def reload_locale(locale) when is_binary(locale) do
    GenServer.call(__MODULE__, {:reload, locale})
  end

  @doc """
  Returns all currently loaded locales.
  """
  @spec loaded_locales() :: [locale()]
  def loaded_locales do
    GenServer.call(__MODULE__, :loaded_locales)
  end

  @impl GenServer
  def init(opts) do
    base_dir = Keyword.fetch!(opts, :base_dir)
    {:ok, %{translations: %{}, base_dir: base_dir}}
  end

  @impl GenServer
  def handle_call({:translate, locale, key, default}, _from, state) do
    result =
      case Map.fetch(state.translations, locale) do
        {:ok, locale_map} -> Map.get(locale_map, key, default)
        :error -> default
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:reload, locale}, _from, state) do
    path = Path.join(state.base_dir, "#{locale}.json")

    case load_from_disk(path) do
      {:ok, translations} ->
        updated = Map.put(state.translations, locale, translations)
        {:reply, :ok, %{state | translations: updated}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl GenServer
  def handle_call(:loaded_locales, _from, state) do
    {:reply, Map.keys(state.translations), state}
  end

  defp load_from_disk(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      if is_map(decoded) do
        {:ok, decoded}
      else
        {:error, "translation file must contain a JSON object"}
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "could not read file #{path}: #{reason}"}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, "invalid JSON in #{path}: #{Exception.message(e)}"}
    end
  end
end
```

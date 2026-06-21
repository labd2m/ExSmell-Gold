```elixir
defmodule I18n.Locale do
  @moduledoc false

  @spec fallback_chain(String.t()) :: [String.t()]
  def fallback_chain(locale) when is_binary(locale) do
    case String.split(locale, "-") do
      [language, _region] -> [locale, language, "en"]
      [language] when language != "en" -> [locale, "en"]
      _ -> [locale]
    end
    |> Enum.uniq()
  end
end

defmodule I18n.Store do
  @moduledoc """
  A supervised translation store with per-locale message catalogs and
  a configurable fallback chain.

  Message keys are dot-separated paths such as `"errors.not_found"`.
  When a key is absent in the requested locale, the store walks the
  fallback chain until a translation is found or all options are
  exhausted. Variable interpolation replaces `%{name}` placeholders
  with values from the bindings map.
  """

  use GenServer

  alias I18n.Locale

  @type locale :: String.t()
  @type message_key :: String.t()
  @type bindings :: %{atom() => term()}
  @type catalog :: %{message_key() => String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put_catalog(locale(), catalog()) :: :ok
  def put_catalog(locale, catalog) when is_binary(locale) and is_map(catalog) do
    GenServer.call(__MODULE__, {:put_catalog, locale, catalog})
  end

  @spec translate(locale(), message_key(), bindings()) ::
          {:ok, String.t()} | {:error, :missing_translation}
  def translate(locale, key, bindings \\ %{})
      when is_binary(locale) and is_binary(key) and is_map(bindings) do
    chain = Locale.fallback_chain(locale)
    GenServer.call(__MODULE__, {:translate, chain, key, bindings})
  end

  @spec translate!(locale(), message_key(), bindings()) :: String.t()
  def translate!(locale, key, bindings \\ %{}) do
    case translate(locale, key, bindings) do
      {:ok, text} -> text
      {:error, :missing_translation} -> "[#{locale}:#{key}]"
    end
  end

  @spec loaded_locales() :: [locale()]
  def loaded_locales, do: GenServer.call(__MODULE__, :loaded_locales)

  @impl GenServer
  def init(_opts) do
    {:ok, %{catalogs: %{}}}
  end

  @impl GenServer
  def handle_call({:put_catalog, locale, catalog}, _from, state) do
    {:reply, :ok, %{state | catalogs: Map.put(state.catalogs, locale, catalog)}}
  end

  def handle_call({:translate, chain, key, bindings}, _from, state) do
    result =
      Enum.find_value(chain, {:error, :missing_translation}, fn locale ->
        with {:ok, catalog} <- Map.fetch(state.catalogs, locale),
             {:ok, template} <- Map.fetch(catalog, key) do
          {:ok, interpolate(template, bindings)}
        else
          _ -> nil
        end
      end)

    {:reply, result, state}
  end

  def handle_call(:loaded_locales, _from, state) do
    {:reply, Map.keys(state.catalogs), state}
  end

  defp interpolate(template, bindings) when map_size(bindings) == 0, do: template

  defp interpolate(template, bindings) do
    Enum.reduce(bindings, template, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
```

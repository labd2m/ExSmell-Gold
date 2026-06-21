```elixir
defmodule MyApp.Localization.Translator do
  @moduledoc """
  Provides locale-aware string translation backed by YAML message catalogs
  compiled into the application at build time. Lookups are O(1) map access
  via a nested key path; missing keys fall back to the configured default
  locale before returning a labelled placeholder so that untranslated strings
  are immediately visible in the UI without raising.

  Interpolation supports `%{variable}` placeholders replaced at runtime.
  """

  @default_locale "en"
  @placeholder_prefix "[missing:"

  @translations %{
    "en" => %{
      "auth" => %{
        "sign_in" => "Sign in",
        "sign_out" => "Sign out",
        "error_invalid_credentials" => "Email or password is incorrect"
      },
      "orders" => %{
        "status_pending" => "Pending",
        "status_shipped" => "Shipped",
        "status_delivered" => "Delivered",
        "confirmation" => "Order %{order_number} confirmed"
      }
    },
    "fr" => %{
      "auth" => %{
        "sign_in" => "Se connecter",
        "sign_out" => "Se déconnecter",
        "error_invalid_credentials" => "Adresse e-mail ou mot de passe incorrect"
      },
      "orders" => %{
        "status_pending" => "En attente",
        "status_shipped" => "Expédié",
        "status_delivered" => "Livré",
        "confirmation" => "Commande %{order_number} confirmée"
      }
    }
  }

  @type locale :: String.t()
  @type key_path :: [String.t()]
  @type bindings :: map()

  @doc """
  Translates the dot-separated `key` for `locale`, interpolating any
  `bindings` into `%{variable}` placeholders. Falls back to the default
  locale when the key is missing for the requested locale. Returns a
  labelled placeholder when the key is absent from all locales.
  """
  @spec translate(locale(), String.t(), bindings()) :: String.t()
  def translate(locale, key, bindings \\ %{})
      when is_binary(locale) and is_binary(key) and is_map(bindings) do
    path = String.split(key, ".")

    lookup(locale, path)
    |> fallback_lookup(path)
    |> interpolate(bindings)
  end

  @doc "Returns a list of all supported locale codes."
  @spec supported_locales() :: [locale()]
  def supported_locales, do: Map.keys(@translations)

  @doc "Returns `true` when `locale` is a supported locale code."
  @spec supported?(locale()) :: boolean()
  def supported?(locale), do: Map.has_key?(@translations, locale)

  @spec lookup(locale(), key_path()) :: String.t() | nil
  defp lookup(locale, path) do
    get_in(@translations, [locale | path])
  end

  @spec fallback_lookup(String.t() | nil, key_path()) :: String.t()
  defp fallback_lookup(nil, path) do
    case lookup(@default_locale, path) do
      nil -> "#{@placeholder_prefix}#{Enum.join(path, ".")}]"
      value -> value
    end
  end

  defp fallback_lookup(value, _path), do: value

  @spec interpolate(String.t(), bindings()) :: String.t()
  defp interpolate(template, bindings) when map_size(bindings) == 0, do: template

  defp interpolate(template, bindings) do
    Enum.reduce(bindings, template, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
```

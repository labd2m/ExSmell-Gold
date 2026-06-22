```elixir
defmodule Notify.TemplateBuilder do
  @moduledoc """
  Builds notification payloads by rendering named templates with caller-supplied
  assigns.

  Templates are fetched from a pluggable store (database, file system, or
  in-memory). Rendering is pure: no side effects occur during template
  evaluation. Locale selection falls back to the default locale when a
  specific translation is absent.
  """

  alias Notify.TemplateBuilder.{TemplateStore, Renderer, BuiltNotification}

  @default_locale "en"

  @doc """
  Builds a notification payload for the given template name, assigns, and locale.
  """
  @spec build(String.t(), map(), keyword()) ::
          {:ok, BuiltNotification.t()} | {:error, String.t()}
  def build(template_name, assigns, opts \\ [])
      when is_binary(template_name) and is_map(assigns) do
    locale = Keyword.get(opts, :locale, @default_locale)
    store = Keyword.get(opts, :store, TemplateStore.default())

    with {:ok, template} <- resolve_template(store, template_name, locale),
         {:ok, subject} <- Renderer.render_string(template.subject_template, assigns),
         {:ok, body} <- Renderer.render_string(template.body_template, assigns) do
      notification = BuiltNotification.new(template_name, subject, body, locale, template.channels)
      {:ok, notification}
    end
  end

  @doc """
  Returns true if a template exists for the given name and locale.
  """
  @spec template_exists?(String.t(), String.t(), module()) :: boolean()
  def template_exists?(template_name, locale, store)
      when is_binary(template_name) and is_binary(locale) and is_atom(store) do
    case store.fetch(template_name, locale) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp resolve_template(store, name, locale) do
    case store.fetch(name, locale) do
      {:ok, template} ->
        {:ok, template}

      {:error, :not_found} when locale != @default_locale ->
        store.fetch(name, @default_locale)

      {:error, :not_found} ->
        {:error, "template #{name} not found for locale #{locale} or default"}
    end
  end
end

defmodule Notify.TemplateBuilder.Renderer do
  @moduledoc "Renders EEx template strings with assigns maps."

  @spec render_string(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def render_string(template_string, assigns) when is_binary(template_string) and is_map(assigns) do
    bindings = Enum.map(assigns, fn {k, v} -> {to_atom_key(k), v} end)
    result = EEx.eval_string(template_string, bindings)
    {:ok, result}
  rescue
    err -> {:error, "template render failed: #{Exception.message(err)}"}
  end

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key(key) when is_binary(key), do: String.to_existing_atom(key)
end

defmodule Notify.TemplateBuilder.BuiltNotification do
  @moduledoc "Immutable rendered notification ready for delivery."

  @enforce_keys [:template_name, :subject, :body, :locale, :channels, :built_at]
  defstruct [:template_name, :subject, :body, :locale, :channels, :built_at]

  @type channel :: :email | :push | :sms
  @type t :: %__MODULE__{
          template_name: String.t(),
          subject: String.t(),
          body: String.t(),
          locale: String.t(),
          channels: [channel()],
          built_at: DateTime.t()
        }

  @spec new(String.t(), String.t(), String.t(), String.t(), [channel()]) :: t()
  def new(name, subject, body, locale, channels) do
    %__MODULE__{
      template_name: name,
      subject: subject,
      body: body,
      locale: locale,
      channels: channels,
      built_at: DateTime.utc_now()
    }
  end
end

defmodule Notify.TemplateBuilder.TemplateStore do
  @moduledoc "Behaviour for notification template stores."

  @type template :: %{
          name: String.t(),
          locale: String.t(),
          subject_template: String.t(),
          body_template: String.t(),
          channels: [atom()]
        }

  @callback fetch(String.t(), String.t()) :: {:ok, template()} | {:error, :not_found | String.t()}

  @spec default() :: module()
  def default, do: Application.get_env(:notify, :template_store, Notify.TemplateBuilder.Stores.Database)
end
```

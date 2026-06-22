```elixir
defmodule MyAppWeb.RequestContext do
  @moduledoc """
  Provides structured per-request context propagation through the Phoenix
  pipeline. Rather than using the process dictionary or global state, all
  context values (current user, tenant, trace ID, locale) are stored in
  `conn.assigns` and threaded explicitly through controller and view layers.
  Helper functions extract typed values from assigns with clear error messages
  when expected context is absent, catching misconfigured pipelines early.
  """

  import Plug.Conn

  alias MyApp.Accounts.{Organisation, User}

  @type locale :: binary()

  # ---------------------------------------------------------------------------
  # Context injection Plug
  # ---------------------------------------------------------------------------

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> maybe_put_locale()
    |> maybe_put_request_id()
    |> maybe_put_user_agent_info()
  end

  # ---------------------------------------------------------------------------
  # Typed accessors
  # ---------------------------------------------------------------------------

  @doc """
  Returns the authenticated user from assigns.
  Raises `KeyError` when the authentication plug has not run.
  """
  @spec current_user!(Plug.Conn.t()) :: User.t()
  def current_user!(%Plug.Conn{assigns: assigns}) do
    case Map.fetch(assigns, :current_user) do
      {:ok, %User{} = user} -> user
      {:ok, nil} -> raise "current_user! called but user is not authenticated"
      :error -> raise "current_user! called but :current_user not in assigns; check pipeline configuration"
    end
  end

  @doc """
  Returns the current user or `nil` for unauthenticated requests.
  """
  @spec current_user(Plug.Conn.t()) :: User.t() | nil
  def current_user(%Plug.Conn{assigns: assigns}), do: Map.get(assigns, :current_user)

  @doc """
  Returns the current user's organisation.
  Raises when the organisation was not loaded alongside the user.
  """
  @spec current_organisation!(Plug.Conn.t()) :: Organisation.t()
  def current_organisation!(%Plug.Conn{assigns: assigns}) do
    case Map.fetch(assigns, :current_organisation) do
      {:ok, %Organisation{} = org} -> org
      _ -> raise "current_organisation! called but :current_organisation not in assigns"
    end
  end

  @doc """
  Returns the request trace ID for logging and error correlation.
  """
  @spec trace_id(Plug.Conn.t()) :: binary() | nil
  def trace_id(%Plug.Conn{assigns: assigns}), do: Map.get(assigns, :trace_id)

  @doc """
  Returns the resolved locale for the request.
  Defaults to `"en"` when not explicitly set.
  """
  @spec locale(Plug.Conn.t()) :: locale()
  def locale(%Plug.Conn{assigns: assigns}), do: Map.get(assigns, :locale, "en")

  @doc """
  Returns `true` when the request is from a mobile user agent.
  """
  @spec mobile?(Plug.Conn.t()) :: boolean()
  def mobile?(%Plug.Conn{assigns: assigns}), do: Map.get(assigns, :mobile_client, false)

  # ---------------------------------------------------------------------------
  # Context building helpers
  # ---------------------------------------------------------------------------

  @doc """
  Puts the current user and their organisation into assigns.
  Called from the authentication plug after successful token verification.
  """
  @spec put_authenticated_user(Plug.Conn.t(), User.t(), Organisation.t()) :: Plug.Conn.t()
  def put_authenticated_user(conn, %User{} = user, %Organisation{} = org) do
    conn
    |> assign(:current_user, user)
    |> assign(:current_organisation, org)
  end

  @doc """
  Puts the locale resolved from Accept-Language or user preferences.
  """
  @spec put_locale(Plug.Conn.t(), locale()) :: Plug.Conn.t()
  def put_locale(conn, locale) when is_binary(locale) do
    assign(conn, :locale, locale)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_put_locale(conn) do
    locale =
      case get_req_header(conn, "accept-language") do
        [header | _] -> parse_primary_language(header)
        [] -> "en"
      end

    assign(conn, :locale, locale)
  end

  defp parse_primary_language(header) do
    header
    |> String.split(",")
    |> List.first("")
    |> String.split(";")
    |> List.first("")
    |> String.trim()
    |> String.downcase()
    |> String.slice(0, 2)
    |> case do
      "" -> "en"
      lang -> lang
    end
  end

  defp maybe_put_request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [id | _] -> assign(conn, :request_id, id)
      [] -> conn
    end
  end

  defp maybe_put_user_agent_info(conn) do
    mobile =
      case get_req_header(conn, "user-agent") do
        [ua | _] -> mobile_agent?(ua)
        [] -> false
      end

    assign(conn, :mobile_client, mobile)
  end

  defp mobile_agent?(ua) do
    Regex.match?(~r/Mobile|Android|iPhone|iPad/i, ua)
  end
end
```

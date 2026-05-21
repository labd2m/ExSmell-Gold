# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Accounts.ProfileFormatter` module
- **Affected function(s)**: `public_view/2`, `admin_view/2`, `display_name/2`, `initials/2`
- **Short explanation**: Formatting user profile data for different views is a pure transformation of struct fields into display-ready strings and maps. There is no I/O, no mutable shared state, and no resource to protect. Wrapping these transforms in a `GenServer` forces every API response that includes user profiles—potentially hundreds per second—to serialize through a single process with no architectural gain.

## Code

```elixir
defmodule Accounts.ProfileFormatter do
  use GenServer

  @moduledoc """
  Formats user profile records into public-facing and admin views.
  Used by REST API serializers, email templates, and the admin dashboard.
  """

  @sensitive_fields [:password_hash, :totp_secret, :recovery_codes,
                     :failed_login_attempts, :locked_until, :internal_notes]

  @role_labels %{
    "superadmin" => "Super Administrator",
    "admin" => "Administrator",
    "moderator" => "Moderator",
    "member" => "Member",
    "readonly" => "Read-only Member",
    "guest" => "Guest"
  }

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because ProfileFormatter uses a GenServer purely as
  # VALIDATION: a container for stateless profile-formatting functions. The process
  # VALIDATION: state is an empty map used nowhere. Profile formatting happens on
  # VALIDATION: every API request that includes user data; serializing all of them
  # VALIDATION: through one process creates a bottleneck in the user-facing API.
  # VALIDATION: Plain module functions would serve the same purpose without any
  # VALIDATION: concurrency cost.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns the safe, public-facing representation of a user profile.
  Strips all sensitive fields.
  """
  def public_view(pid, user) do
    GenServer.call(pid, {:public_view, user})
  end

  @doc """
  Returns the full admin representation, including audit metadata.
  """
  def admin_view(pid, user) do
    GenServer.call(pid, {:admin_view, user})
  end

  @doc """
  Returns the best available display name for a user.
  """
  def display_name(pid, user) do
    GenServer.call(pid, {:display_name, user})
  end

  @doc """
  Returns 1-2 character initials derived from the user's name or email.
  """
  def initials(pid, user) do
    GenServer.call(pid, {:initials, user})
  end

  @doc """
  Returns a formatted role label.
  """
  def role_label(pid, role) do
    GenServer.call(pid, {:role_label, role})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:public_view, user}, _from, state) do
    view = %{
      id: user.id,
      display_name: compute_display_name(user),
      initials: compute_initials(user),
      avatar_url: Map.get(user, :avatar_url),
      role: user.role,
      role_label: Map.get(@role_labels, user.role, user.role),
      member_since: Map.get(user, :inserted_at),
      verified: Map.get(user, :email_verified, false)
    }

    {:reply, {:ok, view}, state}
  end

  @impl true
  def handle_call({:admin_view, user}, _from, state) do
    safe_user = Map.drop(user, @sensitive_fields)

    view =
      safe_user
      |> Map.put(:display_name, compute_display_name(user))
      |> Map.put(:initials, compute_initials(user))
      |> Map.put(:role_label, Map.get(@role_labels, user.role, user.role))
      |> Map.put(:account_age_days, account_age(user))
      |> Map.put(:status, compute_status(user))

    {:reply, {:ok, view}, state}
  end

  @impl true
  def handle_call({:display_name, user}, _from, state) do
    {:reply, {:ok, compute_display_name(user)}, state}
  end

  @impl true
  def handle_call({:initials, user}, _from, state) do
    {:reply, {:ok, compute_initials(user)}, state}
  end

  @impl true
  def handle_call({:role_label, role}, _from, state) do
    {:reply, {:ok, Map.get(@role_labels, role, role)}, state}
  end

  # VALIDATION: SMELL END

  defp compute_display_name(user) do
    cond do
      not is_nil(Map.get(user, :display_name)) -> user.display_name
      not is_nil(Map.get(user, :first_name)) ->
        [user.first_name, Map.get(user, :last_name)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
      true ->
        user.email |> String.split("@") |> hd()
    end
  end

  defp compute_initials(user) do
    name = compute_display_name(user)
    parts = String.split(name, " ", trim: true)

    case parts do
      [single] -> String.first(single) |> String.upcase()
      [first | rest] ->
        last = List.last(rest)
        "#{String.first(first)}#{String.first(last)}" |> String.upcase()
    end
  end

  defp account_age(user) do
    case Map.get(user, :inserted_at) do
      nil -> nil
      dt -> Date.diff(Date.utc_today(), DateTime.to_date(dt))
    end
  end

  defp compute_status(user) do
    cond do
      Map.get(user, :deactivated_at) != nil -> "deactivated"
      Map.get(user, :locked_until) != nil -> "locked"
      Map.get(user, :email_verified, false) == false -> "unverified"
      true -> "active"
    end
  end
end
```

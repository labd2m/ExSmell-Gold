```elixir
defmodule MyAppWeb.Live.AccountSettingsForm do
  @moduledoc """
  A LiveView that handles account settings updates using Ecto changesets
  for validation. The form provides real-time inline error feedback as the
  user types without a full server round-trip on each keystroke. Save events
  go through the full context layer, keeping the LiveView responsible only
  for rendering and input coordination.
  """

  use MyAppWeb, :live_view

  alias MyApp.Accounts
  alias MyApp.Accounts.User

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    user = Accounts.get_user!(session["user_id"])
    changeset = Accounts.change_user(user, %{})

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:changeset, changeset)
      |> assign(:saved, false)
      |> assign(:form, to_form(changeset))

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.change_user(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset), saved: false)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_user(socket.assigns.current_user, params) do
      {:ok, updated_user} ->
        changeset = Accounts.change_user(updated_user, %{})

        socket =
          socket
          |> assign(:current_user, updated_user)
          |> assign(:changeset, changeset)
          |> assign(:form, to_form(changeset))
          |> assign(:saved, true)
          |> put_flash(:info, "Settings updated successfully")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> assign(:form, to_form(changeset))
          |> assign(:saved, false)

        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="settings-container">
      <h1>Account Settings</h1>

      <.form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:display_name]} label="Display Name" />
        <.input field={@form[:email]} type="email" label="Email Address" />
        <.input field={@form[:bio]} type="textarea" label="Bio" />

        <div class="form-actions">
          <.button type="submit" phx-disable-with="Saving...">
            Save Changes
          </.button>
          <%= if @saved do %>
            <span class="success-badge">Saved!</span>
          <% end %>
        </div>
      </.form>

      <section class="danger-zone">
        <h2>Danger Zone</h2>
        <.link href={~p"/account/delete"} method="delete"
               data-confirm="Are you sure? This cannot be undone.">
          Delete Account
        </.link>
      </section>
    </div>
    """
  end
end

defmodule MyApp.Accounts.UserSettings do
  @moduledoc """
  Ecto schema embedded within User for settings-specific changesets.
  Separating settings validation from identity validation prevents
  the User changeset from accumulating unrelated concerns.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "users" do
    field :display_name, :string
    field :email, :string
    field :bio, :string
    timestamps()
  end

  @doc """
  Validates and casts user settings attributes. Email uniqueness is checked
  at the database level via a unique index; the changeset validates format only.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :email, :bio])
    |> validate_required([:display_name, :email])
    |> validate_length(:display_name, min: 2, max: 64)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/, message: "must be a valid email address")
    |> validate_length(:bio, max: 500)
    |> unique_constraint(:email)
    |> update_change(:email, &String.downcase/1)
  end
end
```

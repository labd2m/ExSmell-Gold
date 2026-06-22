```elixir
defmodule MyAppWeb.Live.OnboardingWizard do
  @moduledoc """
  A multi-step onboarding wizard implemented as a single LiveView. Each step
  is a separate form validated against its own changeset so users see
  targeted errors for only the fields on the current step. Completed step
  data accumulates in the socket state and is submitted atomically at the
  final step, keeping the domain context unaware of the multi-step UI pattern.
  """

  use MyAppWeb, :live_view

  alias MyApp.Onboarding
  alias MyApp.Onboarding.Steps

  @steps [:profile, :organisation, :plan, :confirm]

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:current_step, :profile)
      |> assign(:step_data, %{})
      |> assign(:changeset, Steps.Profile.changeset(%{}))
      |> assign(:form, to_form(Steps.Profile.changeset(%{})))

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"step" => step_name, "data" => params}, socket) do
    changeset =
      step_name
      |> String.to_existing_atom()
      |> step_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
  end

  @impl Phoenix.LiveView
  def handle_event("next", %{"step" => step_name, "data" => params}, socket) do
    step = String.to_existing_atom(step_name)
    changeset = step_changeset(step, params)

    if changeset.valid? do
      merged = Map.merge(socket.assigns.step_data, %{step => changeset.changes})
      next = next_step(step)

      socket =
        socket
        |> assign(:step_data, merged)
        |> assign(:current_step, next)
        |> assign_step_form(next, merged)

      {:noreply, socket}
    else
      {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("back", _params, socket) do
    prev = prev_step(socket.assigns.current_step)

    socket =
      socket
      |> assign(:current_step, prev)
      |> assign_step_form(prev, socket.assigns.step_data)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("submit", _params, socket) do
    attrs = flatten_step_data(socket.assigns.step_data)

    case Onboarding.AccountSetup.run(attrs) do
      {:ok, result} ->
        socket =
          socket
          |> put_flash(:info, "Account created! Welcome aboard.")
          |> redirect(to: ~p"/dashboard")

        {:noreply, socket}

      {:error, _step, _reason, _changes} ->
        socket =
          socket
          |> put_flash(:error, "Something went wrong. Please review your details and try again.")

        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="wizard">
      <.step_indicator steps={@steps} current={@current_step} />

      <div class="wizard-body">
        <%= case @current_step do %>
          <% :profile -> %>
            <.profile_form form={@form} />
          <% :organisation -> %>
            <.organisation_form form={@form} />
          <% :plan -> %>
            <.plan_form form={@form} />
          <% :confirm -> %>
            <.confirm_step data={@step_data} />
        <% end %>
      </div>

      <.wizard_nav step={@current_step} steps={@steps} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp step_changeset(:profile, params), do: Steps.Profile.changeset(params)
  defp step_changeset(:organisation, params), do: Steps.Organisation.changeset(params)
  defp step_changeset(:plan, params), do: Steps.Plan.changeset(params)
  defp step_changeset(:confirm, _params), do: Steps.Confirm.changeset(%{})

  defp next_step(:profile), do: :organisation
  defp next_step(:organisation), do: :plan
  defp next_step(:plan), do: :confirm
  defp next_step(:confirm), do: :confirm

  defp prev_step(:organisation), do: :profile
  defp prev_step(:plan), do: :organisation
  defp prev_step(:confirm), do: :plan
  defp prev_step(step), do: step

  defp assign_step_form(socket, step, step_data) do
    existing = Map.get(step_data, step, %{})
    changeset = step_changeset(step, existing)

    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  defp flatten_step_data(step_data) do
    step_data
    |> Map.values()
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp step_index(step), do: Enum.find_index(@steps, &(&1 == step))
end
```

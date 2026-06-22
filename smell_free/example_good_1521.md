```elixir
defmodule Accounts.RegistrationService do
  @moduledoc """
  Orchestrates the user registration flow: validates input, creates
  the user record, provisions a default workspace, and enqueues a
  welcome email.

  All steps are wrapped in a database transaction to guarantee
  consistency. If any step fails, the entire registration is rolled back.
  """

  alias Accounts.Repo
  alias Accounts.User
  alias Accounts.Workspace
  alias Accounts.EmailQueue

  @type registration_params :: %{
          required(:email) => String.t(),
          required(:password) => String.t(),
          optional(:full_name) => String.t()
        }

  @type registration_result ::
          {:ok, %{user: User.t(), workspace: Workspace.t()}}
          | {:error, :email_taken}
          | {:error, :invalid_params, Ecto.Changeset.t()}
          | {:error, :workspace_creation_failed}

  @doc """
  Registers a new user account with a default personal workspace.

  Enqueues a welcome email after successful registration.
  The operation is fully atomic via a database transaction.
  """
  @spec register(registration_params()) :: registration_result()
  def register(%{email: email, password: _} = params) when is_binary(email) do
    Repo.transaction(fn ->
      with {:ok, user} <- create_user(params),
           {:ok, workspace} <- create_workspace(user),
           :ok <- enqueue_welcome_email(user) do
        %{user: user, workspace: workspace}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  @spec create_user(registration_params()) ::
          {:ok, User.t()} | {:error, :email_taken | {:invalid_params, Ecto.Changeset.t()}}
  defp create_user(params) do
    changeset = User.registration_changeset(%User{}, params)

    case Repo.insert(changeset) do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :email) do
          {:error, :email_taken}
        else
          {:error, {:invalid_params, cs}}
        end
    end
  end

  @spec create_workspace(User.t()) ::
          {:ok, Workspace.t()} | {:error, :workspace_creation_failed}
  defp create_workspace(%User{id: user_id, full_name: name}) do
    attrs = %{
      owner_id: user_id,
      name: personal_workspace_name(name),
      plan: :free
    }

    case Repo.insert(Workspace.creation_changeset(%Workspace{}, attrs)) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, _} -> {:error, :workspace_creation_failed}
    end
  end

  @spec enqueue_welcome_email(User.t()) :: :ok
  defp enqueue_welcome_email(%User{id: user_id, email: email}) do
    EmailQueue.enqueue(:welcome, %{user_id: user_id, to: email})
  end

  @spec personal_workspace_name(String.t() | nil) :: String.t()
  defp personal_workspace_name(nil), do: "My Workspace"
  defp personal_workspace_name(name) when is_binary(name), do: "#{name}'s Workspace"

  @spec unwrap_transaction({:ok, map()} | {:error, term()}) :: registration_result()
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, :email_taken}), do: {:error, :email_taken}
  defp unwrap_transaction({:error, :workspace_creation_failed}),
    do: {:error, :workspace_creation_failed}

  defp unwrap_transaction({:error, {:invalid_params, cs}}),
    do: {:error, :invalid_params, cs}

  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
```

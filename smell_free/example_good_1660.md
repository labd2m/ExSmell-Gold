```elixir
defmodule GraphQL.Resolver.Context do
  @moduledoc """
  Carries per-request authentication and authorization state through
  the GraphQL resolver layer.
  """

  @type t :: %__MODULE__{
          current_user: map() | nil,
          loader: Dataloader.Loader.t() | nil,
          ip_address: String.t() | nil
        }

  defstruct [:current_user, :loader, :ip_address]
end

defmodule GraphQL.Resolvers.Users do
  alias GraphQL.Resolver.Context
  alias MyApp.Accounts

  @moduledoc """
  GraphQL resolvers for user-related queries and mutations.
  All operations enforce authentication and authorization through the context.
  """

  @spec me(map(), map(), Context.t()) :: {:ok, map()} | {:error, String.t()}
  def me(_parent, _args, %Context{current_user: nil}) do
    {:error, "Authentication required."}
  end

  def me(_parent, _args, %Context{current_user: user}) do
    {:ok, user}
  end

  @spec get_user(map(), %{id: String.t()}, Context.t()) ::
          {:ok, map()} | {:error, String.t()}
  def get_user(_parent, %{id: id}, %Context{current_user: nil}) when is_binary(id) do
    {:error, "Authentication required."}
  end

  def get_user(_parent, %{id: id}, %Context{current_user: actor}) do
    case Accounts.get_user(id) do
      {:ok, user} when actor.id == user.id or actor.role == :admin ->
        {:ok, user}

      {:ok, _user} ->
        {:error, "Access denied."}

      {:error, :not_found} ->
        {:error, "User not found."}
    end
  end

  @spec update_profile(map(), map(), Context.t()) ::
          {:ok, map()} | {:error, String.t()}
  def update_profile(_parent, _args, %Context{current_user: nil}) do
    {:error, "Authentication required."}
  end

  def update_profile(_parent, %{input: input}, %Context{current_user: user}) do
    case Accounts.update_profile(user, input) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, format_changeset_errors(changeset)}
    end
  end

  @spec deactivate_user(map(), %{id: String.t()}, Context.t()) ::
          {:ok, boolean()} | {:error, String.t()}
  def deactivate_user(_parent, _args, %Context{current_user: %{role: role}})
      when role != :admin do
    {:error, "Admin access required."}
  end

  def deactivate_user(_parent, %{id: id}, %Context{current_user: _admin}) do
    case Accounts.deactivate_user(id) do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:error, "User not found."}
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
```

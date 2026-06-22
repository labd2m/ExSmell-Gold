```elixir
defmodule Prefs.NotificationSettings do
  @moduledoc """
  Context for reading and updating per-user notification preferences.

  Preferences are stored as structured records with channel-level and
  category-level granularity. Updates are validated against a closed set
  of supported channels and categories before persistence.
  """

  import Ecto.Query

  alias Prefs.Repo
  alias Prefs.NotificationSettings.{Setting, ChangeRequest, Validator}

  @type channel :: :email | :sms | :push
  @type category :: :marketing | :transactional | :security | :digest

  @doc """
  Returns all notification settings for a user, with defaults for missing entries.
  """
  @spec get_all(String.t()) :: %{channel() => %{category() => boolean()}}
  def get_all(user_id) when is_binary(user_id) do
    stored =
      Setting
      |> where([s], s.user_id == ^user_id)
      |> Repo.all()
      |> Enum.group_by(& &1.channel, fn s -> {s.category, s.enabled} end)
      |> Map.new(fn {ch, pairs} -> {ch, Map.new(pairs)} end)

    merge_with_defaults(stored)
  end

  @doc """
  Returns the enabled state for a specific channel and category combination.
  """
  @spec get(String.t(), channel(), category()) :: boolean()
  def get(user_id, channel, category)
      when is_binary(user_id) and is_atom(channel) and is_atom(category) do
    user_id
    |> get_all()
    |> get_in([channel, category])
    |> then(&(&1 != false))
  end

  @doc """
  Applies a batch of channel/category preference changes for a user.

  Returns `{:ok, count}` with the number of upserted settings, or an error
  if the request contains unsupported channels or categories.
  """
  @spec update(String.t(), ChangeRequest.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def update(user_id, %ChangeRequest{} = request) when is_binary(user_id) do
    with :ok <- Validator.validate(request) do
      upsert_settings(user_id, request.changes)
    end
  end

  @doc """
  Resets all notification settings for a user to their defaults.
  """
  @spec reset_all(String.t()) :: :ok
  def reset_all(user_id) when is_binary(user_id) do
    Setting
    |> where([s], s.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
  end

  # --- private helpers ---

  defp merge_with_defaults(stored) do
    Validator.all_channels()
    |> Map.new(fn channel ->
      stored_channel = Map.get(stored, channel, %{})

      merged_categories =
        Map.new(Validator.all_categories(), fn cat ->
          {cat, Map.get(stored_channel, cat, default_for(channel, cat))}
        end)

      {channel, merged_categories}
    end)
  end

  defp default_for(:security, _), do: true
  defp default_for(:email, :transactional), do: true
  defp default_for(_, _), do: false

  defp upsert_settings(user_id, changes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    records =
      Enum.map(changes, fn {channel, category, enabled} ->
        %{
          user_id: user_id,
          channel: channel,
          category: category,
          enabled: enabled,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(Setting, records,
        on_conflict: {:replace, [:enabled, :updated_at]},
        conflict_target: [:user_id, :channel, :category]
      )

    {:ok, count}
  end
end

defmodule Prefs.NotificationSettings.ChangeRequest do
  @moduledoc "Value object representing a batch of preference changes."

  @enforce_keys [:changes]
  defstruct [:changes]

  @type change :: {atom(), atom(), boolean()}
  @type t :: %__MODULE__{changes: [change()]}

  @spec new([change()]) :: t()
  def new(changes) when is_list(changes), do: %__MODULE__{changes: changes}
end

defmodule Prefs.NotificationSettings.Validator do
  @moduledoc false

  @channels [:email, :sms, :push]
  @categories [:marketing, :transactional, :security, :digest]

  @spec all_channels() :: [atom()]
  def all_channels, do: @channels

  @spec all_categories() :: [atom()]
  def all_categories, do: @categories

  @spec validate(Prefs.NotificationSettings.ChangeRequest.t()) :: :ok | {:error, String.t()}
  def validate(%{changes: changes}) do
    invalid =
      Enum.reject(changes, fn {ch, cat, enabled} ->
        ch in @channels and cat in @categories and is_boolean(enabled)
      end)

    if invalid == [], do: :ok, else: {:error, "invalid preference changes: #{inspect(invalid)}"}
  end
end
```

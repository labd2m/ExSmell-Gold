```elixir
defmodule Notify.Preferences do
  @moduledoc """
  Context managing user notification channel preferences.
  Supports per-channel opt-in/opt-out and digest frequency configuration.
  """

  import Ecto.Query, warn: false

  alias Notify.Repo
  alias Notify.Preferences.{ChannelConfig, UserPreference}

  @type channel :: :email | :sms | :push | :slack
  @type frequency :: :realtime | :hourly | :daily | :weekly

  @spec get_or_create(String.t()) :: {:ok, UserPreference.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create(user_id) when is_binary(user_id) do
    case Repo.get_by(UserPreference, user_id: user_id) do
      nil -> create_defaults(user_id)
      pref -> {:ok, pref}
    end
  end

  @spec list_enabled_channels(String.t()) :: [channel()]
  def list_enabled_channels(user_id) when is_binary(user_id) do
    UserPreference
    |> where([p], p.user_id == ^user_id)
    |> join(:inner, [p], c in assoc(p, :channel_configs))
    |> where([_p, c], c.enabled == true)
    |> select([_p, c], c.channel)
    |> Repo.all()
    |> Enum.map(&String.to_existing_atom/1)
  end

  @spec update_channel(String.t(), channel(), boolean(), frequency()) ::
          {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_channel(user_id, channel, enabled, frequency)
      when is_binary(user_id) and channel in [:email, :sms, :push, :slack] and
             is_boolean(enabled) and frequency in [:realtime, :hourly, :daily, :weekly] do
    with {:ok, pref} <- get_or_create(user_id),
         config <- find_or_build_config(pref, channel) do
      config
      |> ChannelConfig.update_changeset(%{enabled: enabled, frequency: frequency})
      |> Repo.insert_or_update()
    end
  end

  @spec mute_all(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def mute_all(user_id) when is_binary(user_id) do
    {count, _} =
      ChannelConfig
      |> join(:inner, [c], p in assoc(c, :user_preference))
      |> where([_c, p], p.user_id == ^user_id)
      |> Repo.update_all(set: [enabled: false])

    {:ok, count}
  end

  @spec create_defaults(String.t()) :: {:ok, UserPreference.t()} | {:error, Ecto.Changeset.t()}
  defp create_defaults(user_id) do
    Repo.transaction(fn ->
      with {:ok, pref} <-
             Repo.insert(UserPreference.creation_changeset(%UserPreference{}, %{user_id: user_id})),
           {:ok, _} <- insert_default_channels(pref) do
        pref
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec insert_default_channels(UserPreference.t()) :: {:ok, [ChannelConfig.t()]} | {:error, term()}
  defp insert_default_channels(pref) do
    defaults = [
      %{channel: :email, enabled: true, frequency: :realtime},
      %{channel: :push, enabled: true, frequency: :realtime},
      %{channel: :sms, enabled: false, frequency: :daily},
      %{channel: :slack, enabled: false, frequency: :daily}
    ]

    results =
      Enum.map(defaults, fn attrs ->
        %ChannelConfig{user_preference_id: pref.id}
        |> ChannelConfig.update_changeset(attrs)
        |> Repo.insert()
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, c} -> c end)}
    else
      {:error, hd(errors)}
    end
  end

  @spec find_or_build_config(UserPreference.t(), channel()) :: ChannelConfig.t()
  defp find_or_build_config(pref, channel) do
    channel_string = Atom.to_string(channel)

    Repo.get_by(ChannelConfig,
      user_preference_id: pref.id,
      channel: channel_string
    ) || %ChannelConfig{user_preference_id: pref.id}
  end
end

defmodule Notify.Preferences.ChannelConfig do
  @moduledoc "Ecto schema for a single notification channel configuration row."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "notification_channel_configs" do
    field :channel, :string
    field :enabled, :boolean, default: false
    field :frequency, Ecto.Enum, values: [:realtime, :hourly, :daily, :weekly]

    belongs_to :user_preference, Notify.Preferences.UserPreference

    timestamps(type: :utc_datetime)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = config, params) do
    config
    |> cast(params, [:channel, :enabled, :frequency])
    |> validate_required([:channel, :enabled, :frequency])
    |> unique_constraint([:user_preference_id, :channel])
  end
end
```

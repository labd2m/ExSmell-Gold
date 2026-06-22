```elixir
defmodule Security.Vault.SecretStore do
  @moduledoc """
  Manages application secrets with versioning and access logging.
  Secrets are stored encrypted at rest; each write creates a new version.
  Reads are validated against caller identity before decryption.
  """

  use GenServer

  alias Security.Vault.{EncryptionAdapter, AccessLog}

  @type secret_id :: String.t()
  @type caller_id :: String.t()
  @type version :: pos_integer()
  @type secret_record :: %{
          id: secret_id(),
          versions: [%{version: version(), ciphertext: binary(), created_at: DateTime.t()}],
          acl: MapSet.t(caller_id())
        }
  @type state :: %{secrets: %{secret_id() => secret_record()}, cipher: module()}

  @doc """
  Starts the SecretStore linked to the calling process.

  ## Options
    - `:cipher` - encryption adapter module (default: `EncryptionAdapter.AES256`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a new secret or adds a version to an existing one.
  Returns `{:ok, version}` on success.
  """
  @spec put(secret_id(), binary(), caller_id()) :: {:ok, version()} | {:error, String.t()}
  def put(secret_id, plaintext, caller_id)
      when is_binary(secret_id) and is_binary(plaintext) and is_binary(caller_id) do
    GenServer.call(__MODULE__, {:put, secret_id, plaintext, caller_id})
  end

  @doc """
  Retrieves the latest version of a secret for an authorised caller.
  """
  @spec get(secret_id(), caller_id()) :: {:ok, binary()} | {:error, :not_found | :unauthorized}
  def get(secret_id, caller_id)
      when is_binary(secret_id) and is_binary(caller_id) do
    GenServer.call(__MODULE__, {:get, secret_id, caller_id})
  end

  @doc """
  Grants access to `secret_id` for `grantee_id`.
  """
  @spec grant_access(secret_id(), caller_id(), caller_id()) ::
          :ok | {:error, :not_found | :unauthorized}
  def grant_access(secret_id, requesting_caller, grantee_id)
      when is_binary(secret_id) and is_binary(requesting_caller) and is_binary(grantee_id) do
    GenServer.call(__MODULE__, {:grant, secret_id, requesting_caller, grantee_id})
  end

  @impl GenServer
  def init(opts) do
    cipher = Keyword.get(opts, :cipher, EncryptionAdapter.AES256)
    {:ok, %{secrets: %{}, cipher: cipher}}
  end

  @impl GenServer
  def handle_call({:put, secret_id, plaintext, caller_id}, _from, state) do
    {:ok, ciphertext} = state.cipher.encrypt(plaintext)
    now = DateTime.utc_now()

    {new_version, updated_secrets} =
      case Map.fetch(state.secrets, secret_id) do
        {:ok, record} ->
          ver = length(record.versions) + 1
          version_entry = %{version: ver, ciphertext: ciphertext, created_at: now}
          updated = %{record | versions: record.versions ++ [version_entry]}
          {ver, Map.put(state.secrets, secret_id, updated)}

        :error ->
          record = %{id: secret_id, versions: [%{version: 1, ciphertext: ciphertext, created_at: now}], acl: MapSet.new([caller_id])}
          {1, Map.put(state.secrets, secret_id, record)}
      end

    AccessLog.record(secret_id, caller_id, :write, new_version)
    {:reply, {:ok, new_version}, %{state | secrets: updated_secrets}}
  end

  @impl GenServer
  def handle_call({:get, secret_id, caller_id}, _from, state) do
    with {:ok, record} <- Map.fetch_error(state.secrets, secret_id, :not_found),
         :ok <- assert_authorized(record, caller_id) do
      latest = List.last(record.versions)
      {:ok, plaintext} = state.cipher.decrypt(latest.ciphertext)
      AccessLog.record(secret_id, caller_id, :read, latest.version)
      {:reply, {:ok, plaintext}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:grant, secret_id, requesting_caller, grantee_id}, _from, state) do
    with {:ok, record} <- Map.fetch_error(state.secrets, secret_id, :not_found),
         :ok <- assert_authorized(record, requesting_caller) do
      updated_record = %{record | acl: MapSet.put(record.acl, grantee_id)}
      new_secrets = Map.put(state.secrets, secret_id, updated_record)
      {:reply, :ok, %{state | secrets: new_secrets}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp assert_authorized(%{acl: acl}, caller_id) do
    if MapSet.member?(acl, caller_id), do: :ok, else: {:error, :unauthorized}
  end

  defp map_fetch_error(map, key, error_reason) do
    case Map.fetch(map, key) do
      {:ok, val} -> {:ok, val}
      :error -> {:error, error_reason}
    end
  end
end
```

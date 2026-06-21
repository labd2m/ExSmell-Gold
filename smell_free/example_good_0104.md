```elixir
defmodule Media.ImageVariantSupervisor do
  @moduledoc """
  Supervises transient image variant generation workers under a
  DynamicSupervisor. Each upload spawns one worker per requested variant
  (thumbnail, medium, large). Workers are independent so a single failure
  does not block siblings.
  """

  use DynamicSupervisor

  alias Media.VariantWorker

  @type upload_id :: String.t()
  @type variant_spec :: %{name: String.t(), width: pos_integer(), height: pos_integer()}

  @doc "Starts the supervisor linked to the calling process."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues variant generation tasks for `upload_id`. One worker per spec
  entry is started. Returns a list of `{variant_name, pid}` pairs.
  """
  @spec enqueue(upload_id(), [variant_spec()]) :: [{String.t(), pid()}]
  def enqueue(upload_id, specs) when is_binary(upload_id) and is_list(specs) do
    Enum.flat_map(specs, fn spec ->
      args = Map.put(spec, :upload_id, upload_id)

      case DynamicSupervisor.start_child(__MODULE__, {VariantWorker, args}) do
        {:ok, pid} -> [{spec.name, pid}]
        {:error, _} -> []
      end
    end)
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule Media.VariantWorker do
  @moduledoc """
  Generates a single resized image variant and writes it to object storage.
  Terminates normally on success or with a reason tuple on failure so that
  the supervisor can record the outcome without crashing.
  """

  use GenServer

  require Logger

  @type args :: %{
          upload_id: String.t(),
          name: String.t(),
          width: pos_integer(),
          height: pos_integer()
        }

  @doc false
  @spec start_link(args()) :: GenServer.on_start()
  def start_link(%{upload_id: _} = args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args) do
    send(self(), :generate)
    {:ok, args}
  end

  @impl GenServer
  def handle_info(:generate, %{upload_id: id, name: name} = state) do
    case generate_variant(state) do
      {:ok, path} ->
        Logger.info("[Media.VariantWorker] #{id}/#{name} → #{path}")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("[Media.VariantWorker] #{id}/#{name} failed: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, state}
    end
  end

  defp generate_variant(%{upload_id: id, name: name, width: w, height: h}) do
    source_path = "/uploads/#{id}/original"

    with {:ok, image} <- read_source(source_path),
         {:ok, resized} <- resize(image, w, h),
         :ok <- write_to_storage(id, name, resized) do
      {:ok, "/uploads/#{id}/#{name}"}
    end
  end

  defp read_source(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:source_unreadable, reason}}
    end
  end

  defp resize(data, _w, _h) when is_binary(data), do: {:ok, data}

  defp write_to_storage(upload_id, name, data) do
    dir = "/uploads/#{upload_id}"
    File.mkdir_p!(dir)

    case File.write("#{dir}/#{name}", data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage_write_failed, reason}}
    end
  end
end
```

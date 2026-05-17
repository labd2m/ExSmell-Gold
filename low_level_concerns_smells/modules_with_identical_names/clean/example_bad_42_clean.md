```elixir
# ── file: lib/media/transcoder.ex ───────────────────────────────────────────

defmodule Media.Transcoder do
  @moduledoc """
  Submits and tracks video/audio transcoding jobs via a remote encoder service.
  Defined in `lib/media/transcoder.ex`.
  """

  alias Media.{EncoderClient, JobStore, OutputStore, PresetRegistry}

  @default_preset "h264_720p"
  @poll_timeout_ms 120_000
  @poll_interval_ms 2_000

  @type job_id :: String.t()
  @type asset_id :: String.t()

  @type transcode_job :: %{
    id: job_id(),
    asset_id: asset_id(),
    input_url: String.t(),
    preset: String.t(),
    outputs: [map()],
    status: :queued | :processing | :completed | :failed | :cancelled,
    created_at: DateTime.t(),
    completed_at: DateTime.t() | nil,
    error: String.t() | nil
  }

  @doc """
  Submit a transcoding job for a media asset.
  `input_url` is a pre-signed storage URL; `preset` selects the output profile.
  Returns `{:ok, job_id}` on success.
  """
  @spec submit_job(asset_id(), String.t(), String.t()) ::
          {:ok, job_id()} | {:error, String.t()}
  def submit_job(asset_id, input_url, preset \\ @default_preset) do
    with {:ok, preset_cfg} <- PresetRegistry.fetch(preset),
         {:ok, remote_job_id} <-
           EncoderClient.create_job(%{
             input: input_url,
             outputs: preset_cfg.output_specs,
             webhook_url: callback_url(asset_id)
           }) do
      job = %{
        id: generate_id(),
        asset_id: asset_id,
        input_url: input_url,
        preset: preset,
        remote_id: remote_job_id,
        outputs: [],
        status: :queued,
        created_at: DateTime.utc_now(),
        completed_at: nil,
        error: nil
      }

      JobStore.save(job)
      {:ok, job.id}
    end
  end

  @doc "Fetch the current status of a transcoding job from the remote encoder."
  @spec status(job_id()) :: {:ok, atom()} | {:error, String.t()}
  def status(job_id) do
    with {:ok, job} <- JobStore.fetch(job_id),
         {:ok, remote_status} <- EncoderClient.job_status(job.remote_id) do
      normalised = normalise_status(remote_status)

      if job.status != normalised do
        JobStore.update(job_id, %{status: normalised})
      end

      {:ok, normalised}
    else
      :not_found -> {:error, "Job not found: #{job_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Cancel a queued or in-progress transcoding job."
  @spec cancel_job(job_id()) :: :ok | {:error, String.t()}
  def cancel_job(job_id) do
    with {:ok, job} <- JobStore.fetch(job_id),
         :ok <- check_cancellable(job) do
      EncoderClient.cancel(job.remote_id)
      JobStore.update(job_id, %{status: :cancelled})
    else
      :not_found -> {:error, "Job not found: #{job_id}"}
      {:error, _} = err -> err
    end
  end

  @doc "Return the list of output files produced by a completed job."
  @spec outputs(job_id()) :: {:ok, [map()]} | {:error, String.t()}
  def outputs(job_id) do
    with {:ok, %{status: :completed, remote_id: rid}} <- JobStore.fetch(job_id),
         {:ok, remote_outputs} <- EncoderClient.list_outputs(rid) do
      signed = Enum.map(remote_outputs, &OutputStore.sign_url/1)
      {:ok, signed}
    else
      {:ok, %{status: s}} -> {:error, "Job not completed (status: #{s})"}
      :not_found -> {:error, "Job not found: #{job_id}"}
      err -> err
    end
  end

  @doc "Return all format/codec combinations supported by the encoder service."
  @spec supported_formats() :: {:ok, [map()]} | {:error, String.t()}
  def supported_formats do
    EncoderClient.list_formats()
  end

  defp normalise_status("PENDING"), do: :queued
  defp normalise_status("PROGRESSING"), do: :processing
  defp normalise_status("COMPLETE"), do: :completed
  defp normalise_status("ERROR"), do: :failed
  defp normalise_status("CANCELED"), do: :cancelled
  defp normalise_status(_), do: :queued

  defp check_cancellable(%{status: s}) when s in [:queued, :processing], do: :ok
  defp check_cancellable(%{status: s}), do: {:error, "Cannot cancel job in status: #{s}"}

  defp callback_url(asset_id) do
    base = Application.get_env(:my_app, :base_url, "https://api.example.com")
    "#{base}/webhooks/transcoder/#{asset_id}"
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end


# ── file: lib/media/transcoder_presets.ex

defmodule Media.Transcoder do
  @moduledoc """
  Transcoding preset management: define and register output profiles.
  Was intended to be `Media.Transcoder.Presets` but was accidentally given
  the same module name as the core transcoder.
  """

  alias Media.PresetRegistry

  @builtin_presets %{
    "h264_1080p" => %{
      video_codec: "h264",
      resolution: "1920x1080",
      bitrate_kbps: 5_000,
      audio_codec: "aac",
      container: "mp4"
    },
    "h264_720p" => %{
      video_codec: "h264",
      resolution: "1280x720",
      bitrate_kbps: 2_500,
      audio_codec: "aac",
      container: "mp4"
    },
    "h264_360p" => %{
      video_codec: "h264",
      resolution: "640x360",
      bitrate_kbps: 800,
      audio_codec: "aac",
      container: "mp4"
    },
    "audio_only_aac" => %{
      video_codec: nil,
      audio_codec: "aac",
      audio_bitrate_kbps: 192,
      container: "m4a"
    }
  }

  @doc "Seed the preset registry with built-in presets."
  @spec seed_builtins() :: :ok
  def seed_builtins do
    Enum.each(@builtin_presets, fn {name, cfg} ->
      PresetRegistry.put(name, cfg)
    end)
  end

  @doc "Register a custom preset configuration."
  @spec register(String.t(), map()) :: :ok | {:error, String.t()}
  def register(name, config) when is_binary(name) and is_map(config) do
    with :ok <- validate_preset(config) do
      PresetRegistry.put(name, config)
    end
  end

  @doc "Return all registered preset names."
  @spec list_presets() :: [String.t()]
  def list_presets do
    PresetRegistry.all() |> Map.keys()
  end

  defp validate_preset(%{video_codec: vc, audio_codec: ac})
       when not is_nil(vc) or not is_nil(ac),
       do: :ok

  defp validate_preset(_), do: {:error, "Preset must specify at least one codec"}
end

```

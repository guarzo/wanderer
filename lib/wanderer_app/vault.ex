defmodule WandererApp.Vault do
  use Cloak.Vault, otp_app: :wanderer_app
  require Logger

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: decode_env!("CLOAK_KEY"), iv_length: 12
        }
      )

    {:ok, config}
  end

  # Override Base64 encoding to ensure standard format
  @impl true
  def encode(tag, ciphertext) do
    combo = <<tag::binary, ciphertext::binary>>
    Base.encode64(combo, padding: true)
  end

  # Override Base64 decoding to handle URL-safe format gracefully
  @impl true
  def decode(ciphertext) do
    try do
      Base.decode64!(ciphertext)
    rescue
      ArgumentError ->
        # Try URL-safe conversion
        safe_decode(ciphertext)
    end
  end

  defp safe_decode(ciphertext) do
    # Convert URL-safe to standard
    fixed = 
      ciphertext
      |> :binary.bin_to_list()
      |> Enum.map(fn
        45 -> 43  # - to +
        95 -> 47  # _ to /
        c -> c
      end)
      |> :binary.list_to_bin()

    try do
      Base.decode64!(fixed)
    rescue
      ArgumentError ->
        Logger.error("Failed to decode Base64 data after URL-safe conversion: #{inspect(ciphertext)}")
        raise ArgumentError, "Invalid Base64 encoding in ciphertext"
    end
  end

  defp decode_env!(var) do
    var
    |> System.get_env("OtPJXGfKNyOMWI7TdpcWgOlyNtD9AGSfoAdvEuTQIno=")
    |> Base.decode64!()
  end
end

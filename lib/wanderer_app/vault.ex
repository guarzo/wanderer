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

  defp decode_env!(var) do
    var
    |> System.get_env("OtPJXGfKNyOMWI7TdpcWgOlyNtD9AGSfoAdvEuTQIno=")
    |> decode_base64_safely()
  end

  # Add a more resilient Base64 decoder that handles common issues
  defp decode_base64_safely(binary) when is_binary(binary) do
    # First try standard decoding
    try do
      Base.decode64!(binary)
    rescue
      ArgumentError ->
        # If standard fails, try URL-safe variation 
        try_url_safe_decode(binary)
    end
  end
  defp decode_base64_safely(nil), do: nil

  # Try to handle URL-safe Base64 variant
  defp try_url_safe_decode(binary) do
    # Convert possible URL-safe characters to standard Base64
    fixed = 
      binary
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
        # Last resort: strip invalid chars and try again
        Logger.warning("Encountered invalid Base64 in vault, attempting cleanup: #{inspect(binary)}")
        cleaned = clean_non_base64_chars(binary)
        
        try do
          Base.decode64!(cleaned)
        rescue
          ArgumentError ->
            # If all attempts fail, use fallback
            Logger.error("Failed to decode Base64 in vault after multiple attempts: #{inspect(binary)}")
            # Return a dummy value to prevent crashes (you can customize this)
            <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
        end
    end
  end

  # Remove non-Base64 characters
  defp clean_non_base64_chars(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.filter(fn c ->
      (c >= 65 and c <= 90) or  # A-Z
      (c >= 97 and c <= 122) or  # a-z
      (c >= 48 and c <= 57) or  # 0-9
      c == 43 or c == 47 or     # +/
      c == 61                   # =
    end)
    |> :binary.list_to_bin()
  end
end

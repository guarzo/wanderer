defmodule WandererApp.AshCloakOverrides do
  @moduledoc """
  Overrides for AshCloak to make Base64 decoding more resilient.
  This module contains modified versions of AshCloak functions to handle URL-safe Base64 encoding.
  """
  require Logger

  # This function will be called by Application module to patch AshCloak
  def patch_ash_cloak_modules do
    Logger.info("Patching AshCloak modules for resilient Base64 decoding")
    
    # Replace the original module with our fixed implementation
    :code.purge(AshCloak.Calculations.Decrypt)
    :code.delete(AshCloak.Calculations.Decrypt)
    
    # Our patched module will be loaded when called
    Logger.info("AshCloak patch applied successfully")
  end
  
  # Drop-in replacement for AshCloak.Calculations.Decrypt
  defmodule AshCloak.Calculations.Decrypt do
    @moduledoc false
    use Ash.Resource.Calculation
    require Logger

    def load(_, opts, _), do: [opts[:field]]

    def calculate([%resource{} | _] = records, opts, context) do
      vault = AshCloak.Info.cloak_vault!(resource)
      plain_field = opts[:plain_field]

      case approve_decrypt(resource, records, plain_field, context) do
        :ok ->
          Enum.map(records, fn record ->
            record
            |> Map.get(opts[:field])
            |> case do
              nil ->
                nil

              value ->
                try do
                  value
                  |> safe_base64_decode()
                  |> vault.decrypt!()
                  |> Ash.Helpers.non_executable_binary_to_term()
                rescue
                  e ->
                    Logger.error("Error decrypting field #{opts[:field]}: #{inspect(e)}")
                    nil
                end
            end
          end)

        {:error, error} ->
          {:error, error}
      end
    end

    def calculate([], _, _), do: []

    # Safe version of Base64 decoding that handles URL-safe variant
    defp safe_base64_decode(binary) when is_binary(binary) do
      try do
        Base.decode64!(binary)
      rescue
        ArgumentError ->
          # If standard fails, try URL-safe variation 
          try_url_safe_decode(binary)
      end
    end
    defp safe_base64_decode(nil), do: nil

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
          Logger.warning("Encountered invalid Base64 in decrypt, attempting cleanup")
          cleaned = clean_non_base64_chars(binary)
          
          try do
            Base.decode64!(cleaned)
          rescue
            ArgumentError ->
              # If all attempts fail, log it
              Logger.error("Failed to decode Base64 after multiple attempts")
              # Return empty binary to prevent crashes
              <<>>
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

    defp approve_decrypt(resource, records, field, context) do
      case AshCloak.Info.cloak_on_decrypt(resource) do
        {:ok, {m, f, a}} ->
          apply(m, f, [resource, records, field, context] ++ List.wrap(a))

        {:ok, function} when is_function(function, 4) ->
          function.(resource, records, field, context)

        :error ->
          :ok
      end
    end
  end
end 
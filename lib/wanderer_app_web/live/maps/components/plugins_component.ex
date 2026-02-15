defmodule WandererAppWeb.Maps.PluginsComponent do
  @moduledoc """
  LiveView component for managing plugin configuration on a map.

  Displays available plugins, allows enabling/disabling, and provides
  plugin-specific configuration forms.
  """

  use WandererAppWeb, :live_component
  require Logger

  alias WandererApp.Api.MapPluginConfig
  alias WandererApp.Plugins.PluginRegistry

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       plugins: [],
       configs: %{},
       parsed_configs: %{},
       loading: true,
       error: nil,
       saving: false,
       show_bot_token: false,
       success_message: nil
     )}
  end

  @impl true
  def update(%{map_id: map_id} = assigns, socket) do
    plugins = PluginRegistry.list_plugins()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(plugins: plugins)
     |> load_configs(map_id)}
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("toggle_plugin", %{"plugin" => plugin_name}, socket) do
    map_id = socket.assigns.map_id
    configs = socket.assigns.configs

    case Map.get(configs, plugin_name) do
      nil ->
        # Create new config (enabled)
        default_config = PluginRegistry.default_config(plugin_name)

        case MapPluginConfig.create(%{
               map_id: map_id,
               plugin_name: plugin_name,
               enabled: true,
               config: Jason.encode!(default_config)
             }) do
          {:ok, config} ->
            parsed_configs = socket.assigns.parsed_configs

            {:noreply,
             socket
             |> assign(configs: Map.put(configs, plugin_name, config))
             |> assign(
               parsed_configs: Map.put(parsed_configs, plugin_name, parse_config(config.config))
             )
             |> assign(success_message: "Plugin enabled", error: nil)}

          {:error, reason} ->
            Logger.error("Failed to enable plugin: #{inspect(reason)}")
            {:noreply, assign(socket, error: "Failed to enable plugin")}
        end

      config ->
        # Toggle existing config
        new_enabled = not config.enabled

        case MapPluginConfig.update(config, %{enabled: new_enabled}) do
          {:ok, updated} ->
            parsed_configs = socket.assigns.parsed_configs
            message = if new_enabled, do: "Plugin enabled", else: "Plugin disabled"

            {:noreply,
             socket
             |> assign(configs: Map.put(configs, plugin_name, updated))
             |> assign(
               parsed_configs: Map.put(parsed_configs, plugin_name, parse_config(updated.config))
             )
             |> assign(success_message: message, error: nil)}

          {:error, reason} ->
            Logger.error("Failed to toggle plugin: #{inspect(reason)}")
            {:noreply, assign(socket, error: "Failed to update plugin")}
        end
    end
  end

  @impl true
  def handle_event("toggle_bot_token", _, socket) do
    {:noreply, assign(socket, show_bot_token: !socket.assigns.show_bot_token)}
  end

  @impl true
  def handle_event("save_plugin_config", %{"plugin" => plugin_name} = params, socket) do
    socket = assign(socket, saving: true)
    configs = socket.assigns.configs
    config = Map.get(configs, plugin_name)

    if is_nil(config) do
      {:noreply, assign(socket, saving: false, error: "Plugin not enabled")}
    else
      new_config = build_config_from_params(plugin_name, params)

      case PluginRegistry.validate_config(plugin_name, new_config) do
        {:ok, validated_config} ->
          case MapPluginConfig.update(config, %{config: Jason.encode!(validated_config)}) do
            {:ok, updated} ->
              parsed_configs = socket.assigns.parsed_configs

              {:noreply,
               socket
               |> assign(configs: Map.put(configs, plugin_name, updated))
               |> assign(
                 parsed_configs:
                   Map.put(parsed_configs, plugin_name, parse_config(updated.config))
               )
               |> assign(success_message: "Configuration saved", error: nil, saving: false)}

            {:error, reason} ->
              Logger.error("Failed to save plugin config: #{inspect(reason)}")
              {:noreply, assign(socket, error: "Failed to save configuration", saving: false)}
          end

        {:error, errors} ->
          {:noreply, assign(socket, error: Enum.join(errors, ", "), saving: false)}
      end
    end
  end

  @impl true
  def handle_event("dismiss_message", _, socket) do
    {:noreply, assign(socket, success_message: nil, error: nil)}
  end

  # --- Private ---

  defp load_configs(socket, map_id) do
    case MapPluginConfig.by_map(map_id) do
      {:ok, configs} ->
        configs_map =
          configs
          |> Enum.map(fn c -> {c.plugin_name, c} end)
          |> Map.new()

        parsed_map =
          configs
          |> Enum.map(fn c -> {c.plugin_name, parse_config(c.config)} end)
          |> Map.new()

        assign(socket,
          configs: configs_map,
          parsed_configs: parsed_map,
          loading: false,
          error: nil
        )

      {:error, reason} ->
        Logger.error("Failed to load plugin configs: #{inspect(reason)}")

        assign(socket,
          configs: %{},
          parsed_configs: %{},
          loading: false,
          error: "Failed to load plugin settings"
        )
    end
  end

  defp parse_config(nil), do: %{}
  defp parse_config(""), do: %{}

  defp parse_config(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp build_config_from_params("notifier", params) do
    %{
      "discord" => %{
        "bot_token" => Map.get(params, "bot_token", ""),
        "channels" => %{
          "primary" => Map.get(params, "channel_primary", ""),
          "system_kill" => nilify(Map.get(params, "channel_system_kill", "")),
          "character_kill" => nilify(Map.get(params, "channel_character_kill", "")),
          "system" => nilify(Map.get(params, "channel_system", "")),
          "character" => nilify(Map.get(params, "channel_character", "")),
          "rally" => nilify(Map.get(params, "channel_rally", ""))
        },
        "rally_group_ids" => parse_comma_list(Map.get(params, "rally_group_ids", ""))
      },
      "features" => %{
        "notifications_enabled" => params["notifications_enabled"] == "true",
        "kill_notifications_enabled" => params["kill_notifications_enabled"] == "true",
        "system_notifications_enabled" => params["system_notifications_enabled"] == "true",
        "character_notifications_enabled" => params["character_notifications_enabled"] == "true",
        "rally_notifications_enabled" => params["rally_notifications_enabled"] == "true",
        "wormhole_only_kill_notifications" =>
          params["wormhole_only_kill_notifications"] == "true",
        "track_kspace" => params["track_kspace"] == "true",
        "priority_systems_only" => params["priority_systems_only"] == "true"
      },
      "settings" => %{
        "corporation_kill_focus" =>
          parse_comma_list_int(Map.get(params, "corporation_kill_focus", "")),
        "character_exclude_list" =>
          parse_comma_list_int(Map.get(params, "character_exclude_list", "")),
        "system_exclude_list" => parse_comma_list_int(Map.get(params, "system_exclude_list", ""))
      }
    }
  end

  defp build_config_from_params(_, _params), do: %{}

  defp nilify(""), do: nil
  defp nilify(val), do: val

  defp parse_comma_list(""), do: []

  defp parse_comma_list(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_comma_list(_), do: []

  defp parse_comma_list_int(str) do
    str
    |> parse_comma_list()
    |> Enum.map(fn s ->
      case Integer.parse(s) do
        {n, _} -> n
        :error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_config_value(parsed_configs, plugin_name, path, default) do
    case Map.get(parsed_configs, plugin_name) do
      nil ->
        default

      parsed ->
        case get_in(parsed, path) do
          nil -> default
          value -> value
        end
    end
  end

  defp enabled?(configs, plugin_name) do
    case Map.get(configs, plugin_name) do
      nil -> false
      config -> config.enabled
    end
  end

  defp comma_join(list) when is_list(list), do: Enum.join(list, ", ")
  defp comma_join(_), do: ""

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="plugins-config">
      <%= if @loading do %>
        <div class="flex justify-center py-4">
          <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
        </div>
      <% else %>
        <%= if @error do %>
          <div
            class="border border-red-400 text-red-300 px-4 py-3 rounded mb-4 flex justify-between items-center"
            phx-click="dismiss_message"
            phx-target={@myself}
          >
            <p>{@error}</p>
            <span class="cursor-pointer text-sm">&times;</span>
          </div>
        <% end %>

        <%= if @success_message do %>
          <div
            class="border border-green-400 text-green-300 px-4 py-3 rounded mb-4 flex justify-between items-center"
            phx-click="dismiss_message"
            phx-target={@myself}
          >
            <p>{@success_message}</p>
            <span class="cursor-pointer text-sm">&times;</span>
          </div>
        <% end %>

        <%= for plugin <- @plugins do %>
          <div class="mb-6">
            <div class="flex items-center justify-between mb-3">
              <div>
                <h3 class="text-lg font-semibold">{plugin.display_name}</h3>
                <p class="text-sm text-stone-400">{plugin.description}</p>
              </div>
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  class="checkbox checkbox-primary"
                  checked={enabled?(@configs, plugin.name)}
                  phx-click="toggle_plugin"
                  phx-value-plugin={plugin.name}
                  phx-target={@myself}
                />
                <span class="text-sm">
                  {if enabled?(@configs, plugin.name), do: "Enabled", else: "Disabled"}
                </span>
              </label>
            </div>

            <%= if enabled?(@configs, plugin.name) and plugin.name == "notifier" do %>
              <form
                phx-submit="save_plugin_config"
                phx-target={@myself}
                class="border border-stone-700 rounded p-4 space-y-4"
              >
                <input type="hidden" name="plugin" value="notifier" />

                <%!-- Discord Setup --%>
                <div>
                  <h4 class="text-md font-semibold mb-2 text-stone-300">Discord Setup</h4>
                  <div class="space-y-3">
                    <div>
                      <label class="block text-sm text-stone-400 mb-1">Bot Token *</label>
                      <div class="flex gap-2">
                        <input
                          type={if @show_bot_token, do: "text", else: "password"}
                          name="bot_token"
                          value={
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["discord", "bot_token"],
                              ""
                            )
                          }
                          class="input input-bordered text-sm bg-neutral-800 text-white flex-1"
                          placeholder="Discord bot token"
                        />
                        <button
                          type="button"
                          phx-click="toggle_bot_token"
                          phx-target={@myself}
                          class="btn btn-sm"
                        >
                          {if @show_bot_token, do: "Hide", else: "Show"}
                        </button>
                      </div>
                    </div>
                    <div>
                      <label class="block text-sm text-stone-400 mb-1">Primary Channel ID *</label>
                      <input
                        type="text"
                        name="channel_primary"
                        value={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["discord", "channels", "primary"],
                            ""
                          )
                        }
                        class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                        placeholder="Channel ID for all notifications (required)"
                      />
                    </div>
                    <div class="grid grid-cols-2 gap-3">
                      <div>
                        <label class="block text-sm text-stone-400 mb-1">System Kill Channel</label>
                        <input
                          type="text"
                          name="channel_system_kill"
                          value={
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["discord", "channels", "system_kill"],
                              ""
                            )
                          }
                          class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                          placeholder="Falls back to primary"
                        />
                      </div>
                      <div>
                        <label class="block text-sm text-stone-400 mb-1">
                          Character Kill Channel
                        </label>
                        <input
                          type="text"
                          name="channel_character_kill"
                          value={
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["discord", "channels", "character_kill"],
                              ""
                            )
                          }
                          class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                          placeholder="Falls back to primary"
                        />
                      </div>
                      <div>
                        <label class="block text-sm text-stone-400 mb-1">System Channel</label>
                        <input
                          type="text"
                          name="channel_system"
                          value={
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["discord", "channels", "system"],
                              ""
                            )
                          }
                          class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                          placeholder="Falls back to primary"
                        />
                      </div>
                      <div>
                        <label class="block text-sm text-stone-400 mb-1">Character Channel</label>
                        <input
                          type="text"
                          name="channel_character"
                          value={
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["discord", "channels", "character"],
                              ""
                            )
                          }
                          class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                          placeholder="Falls back to primary"
                        />
                      </div>
                      <div>
                        <label class="block text-sm text-stone-400 mb-1">Rally Channel</label>
                        <input
                          type="text"
                          name="channel_rally"
                          value={
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["discord", "channels", "rally"],
                              ""
                            )
                          }
                          class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                          placeholder="Falls back to primary"
                        />
                      </div>
                      <div>
                        <label class="block text-sm text-stone-400 mb-1">Rally Group IDs</label>
                        <input
                          type="text"
                          name="rally_group_ids"
                          value={
                            comma_join(
                              get_config_value(
                                @parsed_configs,
                                "notifier",
                                ["discord", "rally_group_ids"],
                                []
                              )
                            )
                          }
                          class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                          placeholder="Comma-separated group IDs"
                        />
                      </div>
                    </div>
                  </div>
                </div>

                <%!-- Feature Toggles --%>
                <div>
                  <h4 class="text-md font-semibold mb-2 text-stone-300">Feature Toggles</h4>
                  <div class="grid grid-cols-2 gap-2">
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="notifications_enabled" value="false" />
                      <input
                        type="checkbox"
                        name="notifications_enabled"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "notifications_enabled"],
                            true
                          )
                        }
                      />
                      <span class="text-sm">Notifications Enabled</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="kill_notifications_enabled" value="false" />
                      <input
                        type="checkbox"
                        name="kill_notifications_enabled"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "kill_notifications_enabled"],
                            true
                          )
                        }
                      />
                      <span class="text-sm">Kill Notifications</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="system_notifications_enabled" value="false" />
                      <input
                        type="checkbox"
                        name="system_notifications_enabled"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "system_notifications_enabled"],
                            true
                          )
                        }
                      />
                      <span class="text-sm">System Notifications</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="character_notifications_enabled" value="false" />
                      <input
                        type="checkbox"
                        name="character_notifications_enabled"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "character_notifications_enabled"],
                            true
                          )
                        }
                      />
                      <span class="text-sm">Character Notifications</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="rally_notifications_enabled" value="false" />
                      <input
                        type="checkbox"
                        name="rally_notifications_enabled"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "rally_notifications_enabled"],
                            true
                          )
                        }
                      />
                      <span class="text-sm">Rally Notifications</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="wormhole_only_kill_notifications" value="false" />
                      <input
                        type="checkbox"
                        name="wormhole_only_kill_notifications"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "wormhole_only_kill_notifications"],
                            false
                          )
                        }
                      />
                      <span class="text-sm">Wormhole-only Kills</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="track_kspace" value="false" />
                      <input
                        type="checkbox"
                        name="track_kspace"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "track_kspace"],
                            true
                          )
                        }
                      />
                      <span class="text-sm">Track K-Space</span>
                    </label>
                    <label class="flex items-center gap-2 cursor-pointer py-1">
                      <input type="hidden" name="priority_systems_only" value="false" />
                      <input
                        type="checkbox"
                        name="priority_systems_only"
                        value="true"
                        class="checkbox checkbox-primary checkbox-sm"
                        checked={
                          get_config_value(
                            @parsed_configs,
                            "notifier",
                            ["features", "priority_systems_only"],
                            false
                          )
                        }
                      />
                      <span class="text-sm">Priority Systems Only</span>
                    </label>
                  </div>
                </div>

                <%!-- Filtering --%>
                <div>
                  <h4 class="text-md font-semibold mb-2 text-stone-300">Filtering</h4>
                  <div class="space-y-3">
                    <div>
                      <label class="block text-sm text-stone-400 mb-1">Corporation Kill Focus</label>
                      <input
                        type="text"
                        name="corporation_kill_focus"
                        value={
                          comma_join(
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["settings", "corporation_kill_focus"],
                              []
                            )
                          )
                        }
                        class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                        placeholder="Comma-separated corporation EVE IDs"
                      />
                      <p class="text-xs text-stone-500 mt-1">
                        Kills involving these corps route to character kill channel
                      </p>
                    </div>
                    <div>
                      <label class="block text-sm text-stone-400 mb-1">Character Exclude List</label>
                      <input
                        type="text"
                        name="character_exclude_list"
                        value={
                          comma_join(
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["settings", "character_exclude_list"],
                              []
                            )
                          )
                        }
                        class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                        placeholder="Comma-separated character EVE IDs to exclude"
                      />
                    </div>
                    <div>
                      <label class="block text-sm text-stone-400 mb-1">System Exclude List</label>
                      <input
                        type="text"
                        name="system_exclude_list"
                        value={
                          comma_join(
                            get_config_value(
                              @parsed_configs,
                              "notifier",
                              ["settings", "system_exclude_list"],
                              []
                            )
                          )
                        }
                        class="input input-bordered text-sm bg-neutral-800 text-white w-full"
                        placeholder="Comma-separated system IDs to exclude"
                      />
                    </div>
                  </div>
                </div>

                <div class="flex justify-end">
                  <button
                    type="submit"
                    class="bg-blue-600 hover:bg-blue-700 text-white font-medium py-2 px-6 rounded"
                    disabled={@saving}
                  >
                    {if @saving, do: "Saving...", else: "Save Configuration"}
                  </button>
                </div>
              </form>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end

%{
title: "User-Specific Routes: Personalized Navigation for Shared Maps",
author: "Wanderer Development Team",
cover_image_uri: "/images/news/04-05-user-specific-routes/routes-settings.png",
tags: ~w(routes user-settings),
description: "Learn how we implemented user-specific route settings to provide a personalized navigation experience on shared maps.",
}

---

# User-Specific Routes: Personalized Navigation for Shared Maps

We're excited to announce a significant enhancement to the Wanderer mapping application: user-specific route settings! This feature allows each user to maintain their own route preferences on shared maps, providing a truly personalized navigation experience. In this post, we'll explain how this feature works and the benefits it brings to your mapping experience.

---

## Why User-Specific Settings?

Previously, route settings were global for each map, meaning that when one user changed route preferences (like avoiding wormholes or including mass-critical connections), it affected everyone viewing that map. This created confusion and frustration, especially on maps with many active users who might have different navigation preferences.

With our new implementation, each user can now:
- Configure their own route preferences
- Save these preferences to their account
- See routes calculated based on their personal settings
- Maintain these settings across sessions

All of this happens without affecting other users' experiences on the same map!

---

## How It Works

### 1. Accessing Your Route Settings

Your route settings can be found in the Routes widget on any map. Simply:

1. Open the map you want to navigate
2. Click on the Routes widget in the right sidebar
3. Configure your settings using the available options
4. Your settings will be automatically saved to your account

![Routes Settings Widget](/images/news/04-05-user-specific-routes/routes-widget.png)

### 2. Available Route Settings

You can customize your route preferences with the following options:

- **Path Type**: Choose between shortest, safest, or preferred routes
- **Connection Types**: Include or exclude mass-critical, end-of-life, frigate, or cruise missile connections
- **Region Preferences**: Avoid specific regions like wormhole space, Pochven, EDENCOM, or Triglavian space
- **Special Connections**: Include or exclude Thera connections
- **System Avoidance**: Specify individual systems to avoid in your routes

### 3. Behind the Scenes

When you save your route settings, they're stored in two places:
- In your browser's localStorage (for backward compatibility)
- On our servers, associated with your user account and the specific map

This dual-storage approach ensures that your settings persist across different devices and browsers, while also maintaining compatibility with older versions of the application.

---

## Technical Implementation

For those interested in the technical details, here's how we implemented this feature:

### Database Structure

We enhanced our `MapUserSettings` resource to include a `key` field, allowing us to store different types of settings (routes, widgets, etc.) for each user-map combination. The unique constraint ensures that settings are properly isolated between users.

```elixir
# Example schema structure
defmodule WandererApp.MapUserSettings do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid
    attribute :map_id, :uuid
    attribute :key, :string, default: "default"
    attribute :settings, :map
    timestamps()
  end

  identities do
    identity :by_user_map_key, [:user_id, :map_id, :key]
  end
end
```

### Server-Side Logic

We created a dedicated context module for managing user settings, with functions for retrieving, saving, and deleting settings:

```elixir
# Example context module functions
defmodule WandererApp.Settings do
  def get_user_settings(user_id, map_id, key) do
    # Retrieve settings for the specific user, map, and key
  end

  def save_user_settings(user_id, map_id, key, settings) do
    # Save settings for the specific user, map, and key
  end

  def delete_user_settings(user_id, map_id, key) do
    # Delete settings for the specific user, map, and key
  end
end
```

### Frontend Implementation

On the frontend, we updated our `RoutesProvider` component to load settings from the server first, then fall back to localStorage if needed:

```typescript
// Simplified example of the loading logic
const loadSettings = async () => {
  try {
    // Try to load from server first
    const serverSettings = await loadSettingsFromServer(userId, mapId);
    if (serverSettings) {
      setSettings(mergeWithDefaults(serverSettings));
      return;
    }
    
    // Fall back to localStorage
    const localSettings = loadSettingsFromLocalStorage(mapId);
    if (localSettings) {
      setSettings(mergeWithDefaults(localSettings));
      // Save to server for future use
      saveSettingsToServer(userId, mapId, localSettings);
    }
  } catch (error) {
    console.error('Failed to load settings:', error);
  }
};
```

### Event Handling

We updated our event handlers to include the user ID in route events, ensuring that routes are only pushed to the specific user who requested them:

```elixir
# Example event handler
def handle_server_event(
  %{
    event: :routes,
    payload: {solar_system_id, routes_data, user_id}
  },
  %{assigns: %{current_user: %{id: current_user_id}}} = socket
) when current_user_id == user_id do
  # Only push the event to the user who requested it
  socket
  |> push_event("routes", %{
    solar_system_id: solar_system_id,
    routes: routes_data.routes,
    systems_static_data: routes_data.systems_static_data
  })
end

# Ignore routes events for other users
def handle_server_event(
  %{
    event: :routes,
    payload: {_solar_system_id, _routes_data, _user_id}
  },
  socket
) do
  socket
end
```

---

## Benefits for Users

This implementation provides several key benefits:

1. **Personalized Experience**: Configure routes based on your personal preferences without affecting others
2. **Consistent Settings**: Your settings persist across sessions and devices
3. **Improved Collaboration**: Multiple users can work on the same map with different routing preferences
4. **Backward Compatibility**: The system still works with older clients that use localStorage

---

## Future Enhancements

We're planning to extend this user-specific settings approach to other features in the application, including:

- Widget visibility and positioning
- Map display preferences
- Character tracking options
- Notification settings

Stay tuned for more personalization features coming soon!

---

## Feedback

We'd love to hear your thoughts on this new feature. If you encounter any issues or have suggestions for improvement, please let us know through our feedback form or Discord channel.

Happy mapping!

---

*The Wanderer Development Team* 
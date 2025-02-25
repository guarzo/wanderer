# Map Live Component

The MapLive component is the main component for displaying and interacting with maps in the Wanderer application.

## Features

- Displays interactive maps with character tracking
- Shows character activity data using a React component
- Provides map navigation and controls
- Integrates with various event handlers for different map functionalities

## Integration with React Components

### Character Activity Component

The MapLive component integrates with the React CharacterActivity component to display character activity data. This integration is done through a Phoenix LiveView hook.

#### How it works:

1. **LiveView Template**: The template includes a div with the `phx-hook="CharacterActivity"` attribute and passes the activity data as a JSON string in the `data-activity` attribute.

```heex
<div 
  id="character-activity-react" 
  phx-hook="CharacterActivity"
  data-activity={Jason.encode!(result)}
></div>
```

2. **JavaScript Hook**: The `characterActivity.ts` hook creates a React root and renders the CharacterActivity component with the provided data.

3. **Event Handling**: The hook listens for the `update_activity` event to update the component when new data is available.

4. **LiveView Events**: The MapLive component handles the `show_activity` and `hide_activity` events to show and hide the activity modal.

## Data Flow

1. User clicks the activity button
2. MapLive handles the `show_activity` event
3. MapLive loads the character activity data asynchronously
4. The data is passed to the React component through the `data-activity` attribute
5. The React component renders the data
6. When the user closes the modal, the React component triggers the `hide_activity` event
7. MapLive handles the event and hides the modal

## Event Handlers

The MapLive component uses several event handlers to manage different aspects of the map:

- **MapEventHandler**: Handles general map events
- **MapActivityEventHandler**: Handles character activity events
- **MapCoreEventHandler**: Handles core map functionality

## Logging

The component includes detailed logging to help with debugging:

- Activity data retrieval
- Character counts
- Activity record counts
- Sample of the activity summaries

## Future Improvements

- Consider moving more UI components to React for better performance
- Implement pagination for large datasets
- Add filtering options for character activity 
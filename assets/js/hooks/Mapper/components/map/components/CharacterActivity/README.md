# Character Activity Component

A React component for displaying character activity data in the EVE Online mapping application.

## Features

- Displays character activity data including passages, connections, and signatures
- Implements efficient data display using PrimeReact's DataTable component
- Supports sorting by different columns
- Responsive design with proper scrollbar handling

## Usage

The component is integrated with Phoenix LiveView through a hook:

```heex
<div 
  id="character-activity-react" 
  phx-hook="CharacterActivity"
  data-activity={Jason.encode!(activity_data)}
></div>
```

## Implementation Details

- Uses PrimeReact's DataTable for efficient data display and built-in sorting
- Renders character avatars from EVE Online image server
- Styled with a custom CSS file for consistent appearance
- Integrates seamlessly with the LiveView modal

## Dependencies

- React
- PrimeReact (DataTable, Column)
- Phoenix LiveView (for integration)

## Migration from LiveView

This component was migrated from a Phoenix LiveView component to React for better performance with large datasets and to provide a more responsive user experience. 
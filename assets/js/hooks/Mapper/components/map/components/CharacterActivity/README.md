# Character Activity Component

A React component for displaying character activity data in the EVE Online mapping application.

## Features

- Displays character activity data including passages, connections, and signatures
- Implements virtual scrolling for efficient rendering of large datasets using PrimeReact's VirtualScroller
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

- Uses PrimeReact's VirtualScroller for efficient virtual scrolling
- Maintains sorting state within the component
- Renders character avatars from EVE Online image server
- Styled with a custom CSS file for consistent appearance

## Dependencies

- React
- PrimeReact (VirtualScroller)
- Phoenix LiveView (for integration)

## Migration from LiveView

This component was migrated from a Phoenix LiveView component to React for better performance with large datasets and to provide a more responsive user experience. 
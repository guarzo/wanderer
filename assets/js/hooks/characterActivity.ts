import React from 'react';
import { createRoot } from 'react-dom/client';
import { CharacterActivity } from './Mapper/components/map/components';

// Define the hook with minimal TypeScript annotations
const CharacterActivityHook = {
  mounted() {
    try {
      // Get the activity data from the element's dataset
      const activityData = JSON.parse(this.el.dataset.activity || '[]');
      
      // Create a root for React to render into
      this.root = createRoot(this.el);
      
      // Render the React component
      this.root.render(
        React.createElement(CharacterActivity, {
          activity: activityData
        })
      );
      
      // Handle updates to the activity data
      this.handleEvent('update_activity', data => {
        this.root.render(
          React.createElement(CharacterActivity, {
            activity: data.activity
          })
        );
      });
    } catch (error) {
      console.error('Error in CharacterActivity hook:', error);
    }
  },
  
  updated() {
    // If the component is updated through LiveView, we need to re-render
    // This is handled by the update_activity event
  },
  
  destroyed() {
    // React cleanup happens automatically when the DOM node is removed
  }
};

export default CharacterActivityHook; 
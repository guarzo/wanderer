import React from 'react';
import { createRoot } from 'react-dom/client';
import { CharacterActivity } from './Mapper/components/map/components';

interface CharacterActivityHookType {
  el: HTMLElement;
  root: any;
  pushEvent: (event: string, payload?: any) => void;
  handleEvent: (event: string, callback: (data: any) => void) => void;
}

const CharacterActivityHook = {
  mounted() {
    console.log('CharacterActivity hook mounted');
    
    try {
      // Get the activity data from the element's dataset
      const activityData = JSON.parse(this.el.dataset.activity || '[]');
      console.log(`Parsed activity data with ${activityData.length} entries`);
      
      // Create a root for React to render into
      this.root = createRoot(this.el);
      
      const handleClose = () => {
        console.log('Close button clicked');
        this.pushEvent('hide_activity');
      };
      
      // Render the React component
      this.root.render(
        React.createElement(CharacterActivity, {
          activity: activityData,
          onClose: handleClose
        })
      );
      
      // Handle updates to the activity data
      this.handleEvent('update_activity', (data) => {
        console.log(`Received update_activity event with ${data.activity.length} entries`);
        this.root.render(
          React.createElement(CharacterActivity, {
            activity: data.activity,
            onClose: handleClose
          })
        );
      });
    } catch (error) {
      console.error('Error in CharacterActivity hook:', error);
    }
  },
  
  updated() {
    console.log('CharacterActivity hook updated');
    // If the component is updated through LiveView, we need to re-render
    // This is handled by the update_activity event
  },
  
  destroyed() {
    console.log('CharacterActivity hook destroyed');
    // React cleanup happens automatically when the DOM node is removed
    if (this.root) {
      console.log('CharacterActivity React component unmounted');
    }
  }
} as CharacterActivityHookType;

export default CharacterActivityHook; 
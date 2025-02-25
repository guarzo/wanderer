import { createRoot, Root } from 'react-dom/client';
import React from 'react';
import { CharacterActivity, ActivitySummary } from './Mapper/components/map/components/CharacterActivity';

// Declare global window properties
declare global {
  interface Window {
    React: typeof React;
    ReactDOM: { createRoot: typeof createRoot };
    CharacterActivity: typeof CharacterActivity;
    lastActivityData?: string;
  }
}

// Expose React and the CharacterActivity component to the window object
// @ts-ignore - Extending window object
window.React = React;
// @ts-ignore - Extending window object
window.ReactDOM = { createRoot };
// @ts-ignore - Extending window object
window.CharacterActivity = CharacterActivity;

// Helper function to transform legacy data format to new format
function transformActivityData(data: unknown[]): ActivitySummary[] {
  if (!Array.isArray(data)) {
    return [];
  }

  return data.map(item => {
    if (!item || typeof item !== 'object') {
      return { character_name: 'Unknown Character' };
    }

    const typedItem = item as Record<string, unknown>;

    // If it's already in the new format, return as is
    if (typedItem.character_name !== undefined) {
      return typedItem as unknown as ActivitySummary;
    }

    // Extract character name
    const characterObj = typedItem.character as Record<string, unknown> | undefined;
    const characterName =
      characterObj && typeof characterObj === 'object'
        ? String(characterObj.name || 'Unknown Character')
        : 'Unknown Character';

    // Create result object with simplified property assignments
    return {
      character_name: characterName,
      passages_traveled: typeof typedItem.passages === 'number' ? typedItem.passages : undefined,
      passages: Array.isArray(typedItem.passages) ? (typedItem.passages as string[]) : undefined,
      connections_created: typeof typedItem.connections === 'number' ? typedItem.connections : undefined,
      connections: Array.isArray(typedItem.connections) ? (typedItem.connections as string[]) : undefined,
      signatures_scanned: typeof typedItem.signatures === 'number' ? typedItem.signatures : undefined,
      signatures: Array.isArray(typedItem.signatures) ? (typedItem.signatures as string[]) : undefined,
    };
  });
}

interface CharacterActivityHookType {
  el: HTMLElement;
  root?: Root;
  initialized: boolean;
  activityData: ActivitySummary[];
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  handleEvent: (event: string, callback: (data: Record<string, unknown>) => void) => void;
  pushEvent: (event: string, payload: Record<string, unknown>) => void;
  mounted(): void;
  updated(): void;
  destroyed(): void;
  processActivityData(dataString: string): void;
  initializeReactComponent(): void;
  checkAndProcessData(): boolean;
  observer?: MutationObserver;
}

const CharacterActivityHook: CharacterActivityHookType = {
  el: document.createElement('div'), // This will be replaced at runtime
  initialized: false,
  activityData: [], // Store activity data even if component isn't mounted yet

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  handleEvent(_event: string, _callback: (data: Record<string, unknown>) => void) {
    // This is a placeholder that will be replaced at runtime
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  pushEvent(_event: string, _payload: Record<string, unknown>) {
    // This is a placeholder that will be replaced at runtime
  },

  initializeReactComponent() {
    if (this.initialized) {
      return;
    }

    try {
      // Use the element directly if it's in the DOM
      const isInDOM = document.body.contains(this.el);
      let targetEl = this.el;

      // If the element isn't in the DOM, create a new div and append it to the body
      if (!isInDOM) {
        targetEl = document.createElement('div');
        targetEl.id = 'character-activity-react-fallback';
        targetEl.style.position = 'fixed';
        targetEl.style.top = '50%';
        targetEl.style.left = '50%';
        targetEl.style.transform = 'translate(-50%, -50%)';
        targetEl.style.zIndex = '9999';
        targetEl.style.width = '650px';
        targetEl.style.height = '500px';
        targetEl.style.backgroundColor = '#1e1e2e';
        targetEl.style.border = '2px solid #89b4fa';
        targetEl.style.borderRadius = '8px';
        targetEl.style.boxShadow = '0 0 10px rgba(0, 0, 0, 0.5)';
        targetEl.style.overflow = 'hidden';
        document.body.appendChild(targetEl);
      } else {
        // Ensure the element is visible
        targetEl.style.display = 'block';
        targetEl.style.visibility = 'visible';
        targetEl.style.opacity = '1';
      }

      // Create a React root for the CharacterActivity component
      const root = createRoot(targetEl);
      this.root = root;

      // Render with any stored data we have
      root.render(React.createElement(CharacterActivity, { activity: this.activityData }));

      // Mark as initialized
      this.initialized = true;
    } catch (error) {
      console.error('Error initializing React component:', error);
    }
  },

  processActivityData(dataString: string) {
    try {
      let rawActivity;
      try {
        rawActivity = JSON.parse(dataString);
      } catch (parseError) {
        console.error('Error parsing JSON data:', parseError);
        return;
      }

      // Transform the activity data to ensure it's in the correct format
      const activity = transformActivityData(rawActivity);

      // Store the activity data
      this.activityData = activity;

      // Also store in the global variable for persistence
      window.lastActivityData = dataString;

      // If we have a root, update it
      if (this.root && this.initialized) {
        try {
          this.root.render(React.createElement(CharacterActivity, { activity }));
        } catch (renderError) {
          console.error('Error rendering React component:', renderError);
        }
      } else if (!this.initialized) {
        // If not initialized yet, initialize now
        this.initializeReactComponent();
      } else {
        this.initialized = false;
        this.initializeReactComponent();
      }
    } catch (error) {
      console.error('Error processing activity data:', error);
    }
  },

  mounted() {
    try {
      // Check if the element is in the DOM
      const isInDOM = document.body.contains(this.el);

      // Check if we have global activity data
      if (window.lastActivityData && (!this.el.dataset.activity || this.el.dataset.activity === '')) {
        this.el.setAttribute('data-activity', window.lastActivityData);
      }

      // Process any existing data immediately
      const hasData = this.checkAndProcessData();

      // Only initialize if we're in the DOM or have data
      if (isInDOM || hasData) {
        this.initializeReactComponent();
      }

      // Set up a mutation observer to watch for changes to the element's attributes and DOM insertion
      const observer = new MutationObserver(mutations => {
        // Check if the element is now in the DOM
        const isNowInDOM = document.body.contains(this.el);
        if (isNowInDOM && !this.initialized) {
          this.initializeReactComponent();
        }

        // Check for data-activity attribute changes
        mutations.forEach(mutation => {
          if (mutation.type === 'attributes' && mutation.attributeName === 'data-activity') {
            const activityAttr = this.el.getAttribute('data-activity');
            if (activityAttr) {
              this.processActivityData(activityAttr);
            }
          }
        });
      });

      // Store the observer reference for cleanup
      this.observer = observer;

      // Start observing the element for attribute changes and the document for DOM changes
      observer.observe(this.el, { attributes: true });
      observer.observe(document.body, { childList: true, subtree: true });

      // Listen for updates to the activity data
      this.handleEvent('update_activity', data => {
        if (data && data.activity) {
          const activity = data.activity as ActivitySummary[];

          // Store the activity data
          this.activityData = activity;

          if (this.root && this.initialized) {
            this.root.render(React.createElement(CharacterActivity, { activity }));
          } else if (!this.initialized) {
            this.initializeReactComponent();
          }
        }
      });
    } catch (error) {
      console.error('Error initializing CharacterActivity component:', error);
    }
  },

  checkAndProcessData() {
    try {
      // Check if we have data in the dataset
      if (this.el.dataset.activity) {
        this.processActivityData(this.el.dataset.activity);
        return true;
      }

      // Check if the element has a data-activity attribute (might be empty)
      const activityAttr = this.el.getAttribute('data-activity');
      if (activityAttr !== null && activityAttr.length > 0) {
        this.processActivityData(activityAttr);
        return true;
      }

      return false;
    } catch (error) {
      console.error('Error checking for activity data:', error);
      return false;
    }
  },

  updated() {
    try {
      // Check if the element is in the DOM now
      const isInDOM = document.body.contains(this.el);

      // Process any data that might be available now
      this.checkAndProcessData();

      // Only initialize if we're in the DOM and not already initialized
      if (isInDOM && !this.initialized) {
        this.initializeReactComponent();
      }
    } catch (error) {
      console.error('Error updating CharacterActivity component:', error);
    }
  },

  destroyed() {
    try {
      // Clean up the React root when the element is removed
      if (this.root) {
        this.root.unmount();
      }

      // Disconnect the mutation observer
      if (this.observer) {
        this.observer.disconnect();
        this.observer = undefined;
      }
    } catch (error) {
      console.error('Error cleaning up CharacterActivity component:', error);
    }
  },
};

export default CharacterActivityHook;

/* eslint-disable @typescript-eslint/no-explicit-any */
import { createRoot } from 'react-dom/client';
import Mapper from './MapRoot';
import { PhoenixEventName } from './types/events';

const LAST_VERSION_KEY = 'wandererLastVersion';
const UI_LOADED_EVENT = PhoenixEventName.UI_LOADED;

/**
 * Mapper hook - serves as a bridge between Phoenix LiveView and React
 *
 * This hook initializes the React application and handles communication
 * between Phoenix LiveView and React components.
 */
export default {
  _rootEl: null,
  _errorCount: 0,

  mounted() {
    // Create React root element
    // @ts-ignore
    const rootEl = document.getElementById(this.el.id);
    const activeVersion = localStorage.getItem(LAST_VERSION_KEY);
    // @ts-ignore
    this._rootEl = createRoot(rootEl);

    const handleError = (error: any, componentStack: any) => {
      console.error('Mapper error:', error.message, componentStack);
      this.pushEvent(PhoenixEventName.LOG_MAP_ERROR, { error: error.message, componentStack });
    };

    // Render the React application
    this.render({
      handleEvent: this.handleEventWrapper.bind(this),
      pushEvent: this.pushEvent.bind(this),
      pushEventAsync: this.pushEventAsync.bind(this),
      onError: handleError,
    });

    // Notify the server that the UI is loaded
    try {
      this.pushEvent(UI_LOADED_EVENT, { version: activeVersion });
    } catch (error) {
      console.error('Error pushing UI_LOADED_EVENT:', error);
    }
  },

  /**
   * Wraps the handleEvent method to provide consistent error handling
   */
  handleEventWrapper(event: string, handler: (body: any) => void) {
    // @ts-ignore
    this.handleEvent(event, (body: any) => {
      handler(body);
    });
  },

  /**
   * Handles reconnection to the server
   */
  reconnected() {
    const activeVersion = localStorage.getItem(LAST_VERSION_KEY);
    try {
      this.pushEvent(UI_LOADED_EVENT, { version: activeVersion });
    } catch (error) {
      console.error('Error pushing UI_LOADED_EVENT on reconnect:', error);
    }
  },

  /**
   * Pushes an event to the server and returns a promise with the response
   */
  async pushEventAsync(event: any, payload: any) {
    return new Promise((accept, reject) => {
      try {
        this.pushEvent(event, payload, (reply: any) => {
          accept(reply);
        });
      } catch (error) {
        console.error(`Error in pushEventAsync (${event}):`, error);
        reject(error);
      }
    });
  },

  /**
   * Pushes an event to the server
   */
  pushEvent(event: string, payload: any, callback?: (reply: any) => void): void {
    try {
      // The hook itself already has a pushEvent method from Phoenix LiveView
      if (callback) {
        // @ts-ignore
        return this.__proto__.pushEvent.call(this, event, payload, callback);
      } else {
        // @ts-ignore
        return this.__proto__.pushEvent.call(this, event, payload);
      }
    } catch (error) {
      console.error(`Error in pushEvent (${event}):`, error);
      throw error;
    }
  },

  /**
   * Renders the React application
   */
  render(hooks: any) {
    // @ts-ignore
    this._rootEl.render(<Mapper hooks={hooks} />);
  },

  destroyed() {
    this._rootEl.unmount();
  },
};

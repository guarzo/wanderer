// Define the interface for LiveView hooks
interface ShowCharactersAddAlertHook {
  el: HTMLElement;
  pushEvent: (event: string, payload: Record<string, unknown>) => void;
  mounted(): void;
}

export default {
  mounted() {
    this.pushEvent('restore_show_characters_add_alert', {
      value: localStorage.getItem('wanderer:hide_characters_add_alert') !== 'true',
    });

    document.getElementById('characters-add-alert-hide')?.addEventListener('click', () => {
      localStorage.setItem('wanderer:hide_characters_add_alert', 'true');
    });
  },
} as ShowCharactersAddAlertHook;

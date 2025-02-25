/**
 * VirtualScroll hook for Phoenix LiveView
 * 
 * This hook implements a simple virtual scrolling mechanism for tables
 * with large datasets. It works by only rendering the visible rows and
 * a small buffer above and below the viewport.
 */

const VirtualScroll = {
  mounted() {
    // Store references to important elements
    this.container = this.el;
    this.table = this.el.querySelector('table');
    
    if (!this.table) {
      console.error('VirtualScroll hook requires a table element');
      return;
    }
    
    // Initialize state
    this.rowHeight = 0;
    this.visibleRows = [];
    this.allRows = [];
    this.lastScrollTop = 0;
    this.bufferSize = 10; // Number of extra rows to render above and below viewport
    
    // Setup the virtual scrolling
    this.initVirtualScroll();
    
    // Add scroll event listener
    this.container.addEventListener('scroll', this.handleScroll.bind(this));
    
    // Add resize observer to handle container size changes
    this.resizeObserver = new ResizeObserver(() => {
      this.updateVisibleRows();
    });
    this.resizeObserver.observe(this.container);
  },
  
  destroyed() {
    // Clean up event listeners
    if (this.container) {
      this.container.removeEventListener('scroll', this.handleScroll);
    }
    
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
  },
  
  updated() {
    // Re-initialize when the component updates
    this.initVirtualScroll();
  },
  
  initVirtualScroll() {
    // Get all table rows (excluding header)
    const tbody = this.table.querySelector('tbody');
    if (!tbody) return;
    
    this.allRows = Array.from(tbody.querySelectorAll('tr'));
    
    if (this.allRows.length === 0) return;
    
    // Calculate average row height
    this.rowHeight = this.allRows[0].offsetHeight;
    
    // Initial update of visible rows
    this.updateVisibleRows();
  },
  
  handleScroll() {
    // Skip if we're scrolling horizontally
    if (this.container.scrollLeft !== this.lastScrollLeft) {
      this.lastScrollLeft = this.container.scrollLeft;
      return;
    }
    
    // Update visible rows when scrolling vertically
    if (Math.abs(this.container.scrollTop - this.lastScrollTop) > this.rowHeight / 2) {
      this.lastScrollTop = this.container.scrollTop;
      this.updateVisibleRows();
    }
  },
  
  updateVisibleRows() {
    if (this.allRows.length === 0 || this.rowHeight === 0) return;
    
    const containerHeight = this.container.clientHeight;
    const scrollTop = this.container.scrollTop;
    
    // Calculate which rows should be visible
    const startIndex = Math.max(0, Math.floor(scrollTop / this.rowHeight) - this.bufferSize);
    const endIndex = Math.min(
      this.allRows.length - 1,
      Math.ceil((scrollTop + containerHeight) / this.rowHeight) + this.bufferSize
    );
    
    // Show/hide rows based on visibility
    this.allRows.forEach((row, index) => {
      if (index >= startIndex && index <= endIndex) {
        row.style.display = '';
      } else {
        row.style.display = 'none';
      }
    });
  }
};

export default VirtualScroll; 
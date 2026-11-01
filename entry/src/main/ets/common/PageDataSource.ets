import { PageSeg } from './PageSeg';

/** LazyForEach data source for the reader's page flow (Swiper children). */
export class PageDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: PageSeg[][] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PageSeg[] {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  setItems(items: PageSeg[][]): void {
    this.items = items;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}

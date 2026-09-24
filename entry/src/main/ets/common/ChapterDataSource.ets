import { Chapter } from '../engine/types';

/** LazyForEach data source for the chapter list. */
export class ChapterDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: Chapter[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Chapter {
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

  setItems(items: Chapter[]): void {
    this.items = items;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}
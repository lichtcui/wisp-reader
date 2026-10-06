import { BookSearchItem } from '../engine/types';

/**
 * 一行「选择来源」条目 = 命中该书的某一个书源。
 *
 * 置信度不在搜索结果里，需要在抽屉打开时从已导入书源 join 出来，
 * 所以这里物化一次，避免在 `build` 里逐行查表。
 */
export interface PickerRow {
  /** 稳定唯一 key。不能用 sourceUrl：同一个源可能返回两条同名结果（重复源同理）。 */
  key: string;
  item: BookSearchItem;
  /** 展示名，源名为空时回退 sourceUrl。 */
  name: string;
  confidence: number;
  /** 「最新：第 1234 章」已剥离前缀的章节名，'' 表示该源没给。 */
  chapter: string;
  /** 章节名尾部数字，用于把「更新更靠后」的源排前面；非数字为 0。 */
  chapterNo: number;
}

/**
 * `LazyForEach` 数据源（选择来源列表用一份）。
 * 与 `ChapterDataSource` 同一模式。
 */
export class SourceListDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: PickerRow[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PickerRow {
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

  /** 重新下发整份列表（行定高，虚拟化按可视区自动裁剪）。 */
  setItems(items: PickerRow[]): void {
    this.items = items;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}

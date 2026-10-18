import { SourceRow } from '../model/SourceStore';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';

export function sourceRowStateLabel(state: string): string {
  if (state === 'ok') {
    return '可用';
  }
  if (state === 'noResult') {
    return '无结果';
  }
  if (state === 'timeout') {
    return '超时';
  }
  if (state === 'unavailable') {
    return '不可用';
  }
  return '未测';
}

export function sourceRowMeta(source: SourceRow): string {
  const group: string = source.group.length > 0 ? source.group : '默认';
  const state: string = sourceRowStateLabel(source.detectState);
  if (source.detectState.length === 0) {
    return group + ' · ' + state;
  }
  return group + ' · ' + state + ' · ' + source.respondMs.toString() + 'ms';
}

/** Case-insensitive match over the three fields exposed by SourceRow. */
export function sourceRowMatchesQuery(source: SourceRow, query: string): boolean {
  const needle: string = query.trim().toLowerCase();
  if (needle.length === 0) {
    return true;
  }
  const group: string = source.group.length > 0 ? source.group : '默认';
  return source.name.toLowerCase().indexOf(needle) >= 0 ||
    source.url.toLowerCase().indexOf(needle) >= 0 ||
    group.toLowerCase().indexOf(needle) >= 0;
}

/**
 * Manage-list order: hard failures first, then states that need a recheck,
 * then usable sources. Buckets preserve SourceStore's import order.
 */
export function sortSourceRowsForManage(rows: SourceRow[]): SourceRow[] {
  const needsWork: SourceRow[] = [];
  const recheck: SourceRow[] = [];
  const usable: SourceRow[] = [];
  for (const row of rows) {
    if (row.detectState === 'unavailable') {
      needsWork.push(row);
    } else if (row.detectState === 'ok') {
      usable.push(row);
    } else {
      recheck.push(row);
    }
  }
  return needsWork.concat(recheck, usable);
}

@ComponentV2
export struct SourceManageRow {
  @Param source: SourceRow | undefined = undefined;
  @Event onDetail: () => void = () => {};
  @Event onToggle: (on: boolean) => void = () => {};
  @Event onDelete: () => void = () => {};

  private name(): string {
    const source: SourceRow | undefined = this.source;
    if (source === undefined) {
      return '';
    }
    return source.name.length > 0 ? source.name : source.url;
  }

  private meta(): string {
    const source: SourceRow | undefined = this.source;
    return source === undefined ? '' : sourceRowMeta(source);
  }

  private menuItems(): MenuElement[] {
    const source: SourceRow | undefined = this.source;
    if (source === undefined) {
      return [];
    }
    return [
      {
        value: '详情',
        action: () => this.onDetail()
      },
      {
        value: source.enabled ? '停用' : '启用',
        action: () => this.onToggle(!source.enabled)
      },
      {
        value: '删除',
        action: () => this.onDelete()
      }
    ];
  }

  build() {
    Row() {
      Column({ space: 5 }) {
        Text(this.name())
          .fontSize(16)
          .fontColor($r('app.color.text_1'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.meta())
          .fontSize(12)
          .fontColor($r('app.color.text_3'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.source !== undefined) {
        Toggle({ type: ToggleType.Switch, isOn: this.source.enabled })
          .selectedColor($r('app.color.brand'))
          .onChange((on: boolean) => this.onToggle(on))
          .margin({ left: 8 })
        MoreMenuButton({
          items: this.menuItems(),
          label: '书源操作：' + this.name()
        })
      }
    }
    .width('100%')
    .height(72)
    .padding({ left: 16, right: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.onDetail())
  }
}

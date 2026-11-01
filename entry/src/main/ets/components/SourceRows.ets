import { SourceRow } from '../model/SourceStore';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';

export function sourceRowStateLabel(state: string, mode: string = 'full'): string {
  if (state === 'ok') {
    return mode === 'probe' ? '预检通过（未验证）' : '可用';
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

export function sourceRowMeta(source: SourceRow, mode: string = 'full'): string {
  const group: string = source.group.length > 0 ? source.group : '默认';
  const state: string = sourceRowStateLabel(source.detectState, mode);
  if (source.detectState.length === 0) {
    return group + ' · ' + state;
  }
  return group + ' · ' + state + ' · ' + source.respondMs.toString() + 'ms';
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
  @Param detectMode: string = 'full';
  @Event onDetail: (source: SourceRow) => void = () => {};
  @Event onToggle: (source: SourceRow, on: boolean) => void = () => {};
  @Event onDelete: (source: SourceRow) => void = () => {};

  private name(): string {
    const source: SourceRow | undefined = this.source;
    if (source === undefined) {
      return '';
    }
    return source.name.length > 0 ? source.name : source.url;
  }

  private meta(): string {
    const source: SourceRow | undefined = this.source;
    return source === undefined ? '' : sourceRowMeta(source, this.detectMode);
  }

  private menuItems(): MenuElement[] {
    const source: SourceRow | undefined = this.source;
    if (source === undefined) {
      return [];
    }
    return [
      {
        value: '详情',
        action: () => this.onDetail(source)
      },
      {
        value: source.enabled ? '停用' : '启用',
        action: () => this.onToggle(source, !source.enabled)
      },
      {
        value: '删除',
        action: () => this.onDelete(source)
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
          .onChange((on: boolean) => {
            const source: SourceRow | undefined = this.source;
            if (source !== undefined) {
              this.onToggle(source, on);
            }
          })
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
    .onClick(() => {
      const source: SourceRow | undefined = this.source;
      if (source !== undefined) {
        this.onDetail(source);
      }
    })
  }
}

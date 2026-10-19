import { DETECT_INCREMENTAL_WINDOW_MS } from '../common/Const';
import {
  DETECT_MODE_FULL,
  DETECT_MODE_PROBE,
  DETECT_STATUS_CANCELLED,
  DETECT_STATUS_DONE,
  DETECT_STATUS_FAILED,
  DETECT_STATUS_RUNNING
} from '../model/DetectJob';
import { SourceRow } from '../model/SourceStore';
import {
  SourceManageRow,
  sourceRowMatchesQuery,
  sourceRowStateLabel,
  sortSourceRowsForManage
} from './SourceRows';

const SEARCH_DEBOUNCE_MS: number = 150;
const SCOPE_INCREMENTAL: number = 0;
const SCOPE_ALL: number = 1;
const SCOPE_UNTESTED: number = 2;
const SCOPE_FAILED: number = 3;
const SCOPE_GROUP: number = 4;
const RESULT_ALL: number = 0;
const RESULT_OK: number = 1;
const RESULT_NO_RESULT: number = 2;
const RESULT_TIMEOUT: number = 3;
const RESULT_UNAVAILABLE: number = 4;

class DetectRowsDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: SourceRow[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SourceRow {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  setItems(items: SourceRow[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
struct DetectFilterChip {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Event onSelect: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(13)
      .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selected ? $r('app.color.on_brand') : $r('app.color.text_2'))
      .backgroundColor(this.selected ? $r('app.color.brand') : $r('app.color.bg_pill'))
      .height(32)
      .padding({ left: 14, right: 14 })
      .borderRadius(16)
      .maxLines(1)
      .onClick(() => this.onSelect())
  }
}

@ComponentV2
export struct DetectPanel {
  @Param rows: SourceRow[] = [];
  @Param status: string = '';
  @Param mode: string = DETECT_MODE_FULL;
  @Param total: number = 0;
  @Param done: number = 0;
  @Param startedAt: number = 0;
  @Param updatedAt: number = 0;
  @Param message: string = '';
  @Param backgroundState: string = 'inactive';
  @Param clockNow: number = 0;
  @Param launching: boolean = false;
  @Param canResume: boolean = false;

  @Event onStart: (mode: string, sourceIds: string[]) => void = () => {};
  @Event onCancel: () => void = () => {};
  @Event onResume: () => void = () => {};
  @Event onDetail: (source: SourceRow) => void = () => {};
  @Event onToggle: (source: SourceRow, on: boolean) => void = () => {};
  @Event onDelete: (source: SourceRow) => void = () => {};
  @Event onDisableUnavailable: (sourceIds: number[]) => void = () => {};
  @Event onDeleteUnavailable: (sourceIds: number[]) => void = () => {};

  @Local scope: number = SCOPE_INCREMENTAL;
  @Local scopeGroup: string | undefined = undefined;
  @Local groups: string[] = [];
  @Local query: string = '';
  @Local appliedQuery: string = '';
  @Local resultFilter: number = RESULT_ALL;
  @Local showRules: boolean = false;
  @Local enabledCount: number = 0;
  @Local incrementCount: number = 0;
  @Local scopeCount: number = 0;
  @Local untestedCount: number = 0;
  @Local failedCount: number = 0;
  @Local resultTotal: number = 0;
  @Local resultOk: number = 0;
  @Local resultNoResult: number = 0;
  @Local resultTimeout: number = 0;
  @Local resultUnavailable: number = 0;
  @Local visibleCount: number = 0;
  @Local unavailableIds: number[] = [];

  private dataSource: DetectRowsDataSource = new DetectRowsDataSource();
  private listScroller: Scroller = new Scroller();
  private debounceId: number = -1;

  aboutToAppear(): void {
    this.refreshProjection();
  }

  aboutToDisappear(): void {
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
  }

  @Monitor('rows')
  onRowsChanged(): void {
    this.refreshProjection();
  }

  private refreshProjection(): void {
    const groups: string[] = this.collectGroups(this.rows);
    this.groups = groups;
    if (this.scopeGroup !== undefined && groups.indexOf(this.scopeGroup) < 0) {
      this.scopeGroup = undefined;
      if (this.scope === SCOPE_GROUP) {
        this.scope = SCOPE_INCREMENTAL;
      }
    }

    let enabled: number = 0;
    let incremental: number = 0;
    let untested: number = 0;
    let failed: number = 0;
    const now: number = this.clockNow > 0 ? this.clockNow : Date.now();
    for (const row of this.rows) {
      if (!row.enabled) {
        continue;
      }
      enabled += 1;
      if (row.detectState.length === 0) {
        untested += 1;
      }
      if (row.detectState === 'unavailable') {
        failed += 1;
      }
      if (this.inIncrementalScope(row, now)) {
        incremental += 1;
      }
    }
    this.enabledCount = enabled;
    this.incrementCount = incremental;
    this.untestedCount = untested;
    this.failedCount = failed;
    this.scopeCount = this.countForScope(now);

    const searched: SourceRow[] = [];
    let ok: number = 0;
    let noResult: number = 0;
    let timeout: number = 0;
    let unavailable: number = 0;
    const unavailableIds: number[] = [];
    for (const row of this.rows) {
      if (row.detectState === 'ok') {
        ok += 1;
      } else if (row.detectState === 'noResult') {
        noResult += 1;
      } else if (row.detectState === 'timeout') {
        timeout += 1;
      } else if (row.detectState === 'unavailable') {
        unavailable += 1;
        unavailableIds.push(row.id);
      }
      if (sourceRowMatchesQuery(row, this.appliedQuery)) {
        searched.push(row);
      }
    }
    this.resultOk = ok;
    this.resultNoResult = noResult;
    this.resultTimeout = timeout;
    this.resultUnavailable = unavailable;
    this.unavailableIds = unavailableIds;

    const visible: SourceRow[] = [];
    for (const row of searched) {
      if (this.resultFilterMatches(row)) {
        visible.push(row);
      }
    }
    const sorted: SourceRow[] = sortSourceRowsForManage(visible);
    this.resultTotal = searched.length;
    this.dataSource.setItems(sorted);
    this.visibleCount = sorted.length;
    if ((this.resultFilter === RESULT_OK && ok === 0) ||
      (this.resultFilter === RESULT_NO_RESULT && noResult === 0) ||
      (this.resultFilter === RESULT_TIMEOUT && timeout === 0) ||
      (this.resultFilter === RESULT_UNAVAILABLE && unavailable === 0)) {
      this.resultFilter = RESULT_ALL;
      this.dataSource.setItems(sortSourceRowsForManage(searched));
      this.visibleCount = searched.length;
    }
  }

  private collectGroups(rows: SourceRow[]): string[] {
    const seen: Set<string> = new Set<string>();
    const groups: string[] = [];
    for (const row of rows) {
      const group: string = row.group.trim();
      if (!seen.has(group)) {
        seen.add(group);
        groups.push(group);
      }
    }
    groups.sort((left: string, right: string): number => {
      const a: string = left.length > 0 ? left : '默认';
      const b: string = right.length > 0 ? right : '默认';
      return a < b ? -1 : (a > b ? 1 : 0);
    });
    return groups;
  }

  private inIncrementalScope(row: SourceRow, now: number): boolean {
    if (!row.enabled) {
      return false;
    }
    if (row.detectState.length === 0 || row.detectState === 'unavailable') {
      return true;
    }
    return row.detectAt <= 0 || now - row.detectAt >= DETECT_INCREMENTAL_WINDOW_MS;
  }

  private countForScope(now: number): number {
    if (this.scope === SCOPE_ALL) {
      return this.enabledCount;
    }
    if (this.scope === SCOPE_UNTESTED) {
      return this.untestedCount;
    }
    if (this.scope === SCOPE_FAILED) {
      return this.failedCount;
    }
    if (this.scope === SCOPE_GROUP) {
      let count: number = 0;
      const group: string = this.scopeGroup === undefined ? '' : this.scopeGroup;
      for (const row of this.rows) {
        if (row.enabled && row.group.trim() === group) {
          count += 1;
        }
      }
      return count;
    }
    return this.incrementCount;
  }

  private resultFilterMatches(row: SourceRow): boolean {
    if (this.resultFilter === RESULT_OK) {
      return row.detectState === 'ok';
    }
    if (this.resultFilter === RESULT_NO_RESULT) {
      return row.detectState === 'noResult';
    }
    if (this.resultFilter === RESULT_TIMEOUT) {
      return row.detectState === 'timeout';
    }
    if (this.resultFilter === RESULT_UNAVAILABLE) {
      return row.detectState === 'unavailable';
    }
    return true;
  }

  private selectScope(scope: number): void {
    this.scope = scope;
    if (scope !== SCOPE_GROUP) {
      this.scopeGroup = undefined;
    }
    this.scopeCount = this.countForScope(this.clockNow > 0 ? this.clockNow : Date.now());
  }

  private selectGroup(group: string | undefined): void {
    this.scopeGroup = group;
    this.scope = group === undefined ? SCOPE_INCREMENTAL : SCOPE_GROUP;
    this.scopeCount = this.countForScope(this.clockNow > 0 ? this.clockNow : Date.now());
  }

  private selectResultFilter(filter: number): void {
    this.resultFilter = filter;
    this.refreshVisibleRows();
  }

  private refreshVisibleRows(): void {
    const visible: SourceRow[] = [];
    for (const row of this.rows) {
      if (sourceRowMatchesQuery(row, this.appliedQuery) && this.resultFilterMatches(row)) {
        visible.push(row);
      }
    }
    const sorted: SourceRow[] = sortSourceRowsForManage(visible);
    this.dataSource.setItems(sorted);
    this.visibleCount = sorted.length;
  }

  private scheduleQuery(value: string): void {
    this.query = value;
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
    }
    this.debounceId = setTimeout((): void => {
      this.debounceId = -1;
      this.appliedQuery = value;
      this.refreshProjection();
      this.listScroller.scrollEdge(Edge.Top);
    }, SEARCH_DEBOUNCE_MS);
  }

  private clearQuery(): void {
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
    this.query = '';
    this.appliedQuery = '';
    this.refreshProjection();
  }

  private currentScopeIds(): string[] {
    const now: number = this.clockNow > 0 ? this.clockNow : Date.now();
    const ids: string[] = [];
    for (const row of this.rows) {
      if (this.matchesScope(row, now)) {
        ids.push(row.id.toString());
      }
    }
    return ids;
  }

  private enabledIds(): string[] {
    const ids: string[] = [];
    for (const row of this.rows) {
      if (row.enabled) {
        ids.push(row.id.toString());
      }
    }
    return ids;
  }

  private matchesScope(row: SourceRow, now: number): boolean {
    if (this.scope === SCOPE_ALL) {
      return row.enabled;
    }
    if (this.scope === SCOPE_UNTESTED) {
      return row.enabled && row.detectState.length === 0;
    }
    if (this.scope === SCOPE_FAILED) {
      return row.enabled && row.detectState === 'unavailable';
    }
    if (this.scope === SCOPE_GROUP) {
      const group: string = this.scopeGroup === undefined ? '' : this.scopeGroup;
      return row.enabled && row.group.trim() === group;
    }
    return this.inIncrementalScope(row, now);
  }

  private startProbe(): void {
    const ids: string[] = this.currentScopeIds();
    if (ids.length > 0) {
      this.onStart(DETECT_MODE_PROBE, ids);
    }
  }

  private startFull(): void {
    const ids: string[] = this.enabledIds();
    if (ids.length > 0) {
      this.onStart(DETECT_MODE_FULL, ids);
    }
  }

  private modeLabel(): string {
    return this.mode === DETECT_MODE_PROBE ? '预检' : '完整检测';
  }

  private okLabel(): string {
    return sourceRowStateLabel('ok', this.mode);
  }

  private jobTitle(): string {
    if (this.status === DETECT_STATUS_RUNNING) {
      return '运行中 · ' + this.modeLabel();
    }
    if (this.status === DETECT_STATUS_DONE) {
      return '检测完成 · ' + this.modeLabel();
    }
    if (this.status === DETECT_STATUS_CANCELLED) {
      return '已取消 · ' + this.modeLabel();
    }
    if (this.status === DETECT_STATUS_FAILED) {
      return '检测失败 · ' + this.modeLabel();
    }
    return '尚未检测';
  }

  private elapsedMs(): number {
    if (this.startedAt <= 0) {
      return 0;
    }
    const end: number = this.status === DETECT_STATUS_RUNNING && this.clockNow > 0 ? this.clockNow : this.updatedAt;
    return Math.max(0, end - this.startedAt);
  }

  private remainingMs(): number {
    if (this.status !== DETECT_STATUS_RUNNING || this.done <= 0 || this.total <= this.done) {
      return 0;
    }
    return Math.floor(this.elapsedMs() * (this.total - this.done) / this.done);
  }

  private durationText(ms: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(ms / 1000));
    const hours: number = Math.floor(totalSeconds / 3600);
    const minutes: number = Math.floor((totalSeconds % 3600) / 60);
    const seconds: number = totalSeconds % 60;
    if (hours > 0) {
      return hours.toString() + ':' + this.pad2(minutes) + ':' + this.pad2(seconds);
    }
    return this.pad2(minutes) + ':' + this.pad2(seconds);
  }

  private pad2(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }

  private backgroundLabel(): string {
    if (this.backgroundState === 'degraded') {
      return '后台任务不可用，离开应用会暂停';
    }
    if (this.backgroundState === 'active') {
      return '后台继续运行';
    }
    if (this.backgroundState === 'requesting') {
      return '正在申请后台运行';
    }
    return '仅前台运行';
  }

  private groupLabel(): string {
    if (this.scope !== SCOPE_GROUP || this.scopeGroup === undefined) {
      return '分组';
    }
    return '分组 · ' + (this.scopeGroup.length > 0 ? this.scopeGroup : '默认');
  }

  private groupMenuItems(): MenuElement[] {
    const items: MenuElement[] = [{
      value: '全部分组',
      action: () => this.selectGroup(undefined)
    }];
    for (const group of this.groups) {
      items.push({
        value: group.length > 0 ? group : '默认',
        action: () => this.selectGroup(group)
      });
    }
    return items;
  }

  private primaryActionText(): string {
    if (this.launching) {
      return this.status === DETECT_STATUS_RUNNING ? '正在停止…' : '正在准备…';
    }
    if (this.status === DETECT_STATUS_RUNNING) {
      return '取消检测';
    }
    if (this.canResume) {
      return '继续本轮';
    }
    return '开始检测';
  }

  private primaryActionEnabled(): boolean {
    if (this.launching) {
      return false;
    }
    if (this.status === DETECT_STATUS_RUNNING) {
      return true;
    }
    if (this.canResume) {
      return true;
    }
    return this.scopeCount > 0;
  }

  private primaryAction(): void {
    if (this.status === DETECT_STATUS_RUNNING) {
      this.onCancel();
    } else if (this.canResume) {
      this.onResume();
    } else {
      this.startProbe();
    }
  }

  @Builder
  rangeBar() {
    Column({ space: 8 }) {
      Scroll() {
        Row({ space: 8 }) {
          DetectFilterChip({
            label: '增量 ' + this.incrementCount.toString(),
            selected: this.scope === SCOPE_INCREMENTAL,
            onSelect: () => this.selectScope(SCOPE_INCREMENTAL)
          })
          DetectFilterChip({
            label: '全部 ' + this.enabledCount.toString(),
            selected: this.scope === SCOPE_ALL,
            onSelect: () => this.selectScope(SCOPE_ALL)
          })
          DetectFilterChip({
            label: '未测 ' + this.untestedCount.toString(),
            selected: this.scope === SCOPE_UNTESTED,
            onSelect: () => this.selectScope(SCOPE_UNTESTED)
          })
          DetectFilterChip({
            label: '上次失败 ' + this.failedCount.toString(),
            selected: this.scope === SCOPE_FAILED,
            onSelect: () => this.selectScope(SCOPE_FAILED)
          })
          Text(this.groupLabel())
            .fontSize(13)
            .fontColor(this.scope === SCOPE_GROUP ? $r('app.color.on_brand') : $r('app.color.text_2'))
            .backgroundColor(this.scope === SCOPE_GROUP ? $r('app.color.brand') : $r('app.color.bg_pill'))
            .height(32)
            .padding({ left: 14, right: 14 })
            .borderRadius(16)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .bindMenu(this.groupMenuItems())
        }
        .padding({ right: 16 })
      }
      .width('100%')
      .height(32)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)

      Text(this.scopeHelp())
        .fontSize(12)
        .fontColor($r('app.color.text_4'))
        .width('100%')
        .maxLines(2)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
  }

  private scopeHelp(): string {
    if (this.scope === SCOPE_GROUP) {
      return '本轮检测 ' + this.scopeCount.toString() + ' 个启用书源；全部重测仍覆盖所有启用源。';
    }
    if (this.scope === SCOPE_ALL) {
      return '本轮检测 ' + this.scopeCount.toString() + ' 个启用书源；3000 源约 4-6 分钟，实际受网络影响。';
    }
    if (this.scope === SCOPE_UNTESTED) {
      return '本轮只检测 ' + this.scopeCount.toString() + ' 个从未检测的启用书源。';
    }
    if (this.scope === SCOPE_FAILED) {
      return '本轮只检测 ' + this.scopeCount.toString() + ' 个上次判定为不可用的启用书源。';
    }
    return '增量默认检测未测、上次失败或 7 天未检测的 ' + this.scopeCount.toString() + ' 个启用书源。';
  }

  @Builder
  jobCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor(this.jobDotColor())
        Text(this.jobTitle())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_1'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.startedAt > 0) {
          Text(this.durationText(this.elapsedMs()))
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
        }
      }
      .width('100%')

      if (this.status === DETECT_STATUS_RUNNING || this.status === DETECT_STATUS_DONE ||
        this.status === DETECT_STATUS_CANCELLED || this.status === DETECT_STATUS_FAILED) {
        Row({ space: 10 }) {
          Progress({
            value: this.done,
            total: this.total > 0 ? this.total : 1,
            type: ProgressType.Linear
          })
            .layoutWeight(1)
            .color($r('app.color.brand'))
            .backgroundColor($r('app.color.bg_pill'))
            .height(6)
          Text(this.done.toString() + ' / ' + this.total.toString())
            .fontSize(12)
            .fontColor($r('app.color.text_3'))
        }
        .width('100%')
      }

      if (this.status === DETECT_STATUS_RUNNING) {
        Row() {
          Text(this.backgroundLabel())
            .fontSize(12)
            .fontColor(this.backgroundState === 'degraded' ? $r('app.color.warning') : $r('app.color.text_4'))
          Blank()
          if (this.remainingMs() > 0) {
            Text('预计剩余 ' + this.durationText(this.remainingMs()))
              .fontSize(12)
              .fontColor($r('app.color.text_4'))
          }
        }
        .width('100%')
      } else if (this.status === DETECT_STATUS_DONE) {
        Text('本轮已检测 ' + this.done.toString() + ' 个书源；结果保留在本页。')
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
          .width('100%')
      } else if (this.status === DETECT_STATUS_CANCELLED) {
        Text('已保留本轮结果。' + (this.canResume ? '继续时只处理剩余书源。' : '重新开始会建立新一轮。'))
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
          .width('100%')
      } else if (this.status === DETECT_STATUS_FAILED) {
        Text(this.message.length > 0 ? this.message : '检测作业失败，可继续处理剩余书源。')
          .fontSize(12)
          .fontColor($r('app.color.warning'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row({ space: 10 }) {
        Button(this.primaryActionText())
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .backgroundColor(this.status === DETECT_STATUS_RUNNING ?
            $r('app.color.bg_pill') : $r('app.color.brand'))
          .fontColor(this.status === DETECT_STATUS_RUNNING ? $r('app.color.text_2') : $r('app.color.on_brand'))
          .borderRadius(20)
          .enabled(this.primaryActionEnabled())
          .accessibilityText(this.primaryActionText())
          .onClick(() => this.primaryAction())
        if (this.status !== DETECT_STATUS_RUNNING) {
          Button('全部重测')
            .height(40)
            .fontSize(14)
            .fontColor($r('app.color.text_2'))
            .backgroundColor($r('app.color.bg_pill'))
            .borderRadius(20)
            .enabled(!this.launching && this.enabledCount > 0)
            .accessibilityText('全部重测 ' + this.enabledCount.toString() + ' 个启用书源')
            .onClick(() => this.startFull())
        }
      }
      .width('100%')

    }
    .width('100%')
    .padding(14)
    .margin({ left: 16, right: 16, bottom: 10 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  private jobDotColor(): Resource {
    if (this.status === DETECT_STATUS_RUNNING) {
      return $r('app.color.info');
    }
    if (this.status === DETECT_STATUS_FAILED) {
      return $r('app.color.warning');
    }
    if (this.status === DETECT_STATUS_DONE) {
      return $r('app.color.brand');
    }
    return $r('app.color.text_4');
  }

  @Builder
  resultHeader() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(18)
          .fontColor([$r('app.color.text_4')])
        TextInput({ text: this.query, placeholder: '搜索检测结果' })
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.text_1'))
          .placeholderColor($r('app.color.text_5'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 8, right: 0 })
          .onChange((value: string) => this.scheduleQuery(value))
        if (this.query.length > 0) {
          Text('✕')
            .fontSize(14)
            .fontColor($r('app.color.text_4'))
            .padding({ left: 6, right: 4, top: 8, bottom: 8 })
            .onClick(() => this.clearQuery())
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 8 })
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(22)

      Scroll() {
        Row({ space: 8 }) {
          DetectFilterChip({
            label: '全部 ' + this.resultTotal.toString(),
            selected: this.resultFilter === RESULT_ALL,
            onSelect: () => this.selectResultFilter(RESULT_ALL)
          })
          if (this.resultOk > 0) {
            DetectFilterChip({
              label: this.okLabel() + ' ' + this.resultOk.toString(),
              selected: this.resultFilter === RESULT_OK,
              onSelect: () => this.selectResultFilter(RESULT_OK)
            })
          }
          if (this.resultNoResult > 0) {
            DetectFilterChip({
              label: '无结果 ' + this.resultNoResult.toString(),
              selected: this.resultFilter === RESULT_NO_RESULT,
              onSelect: () => this.selectResultFilter(RESULT_NO_RESULT)
            })
          }
          if (this.resultTimeout > 0) {
            DetectFilterChip({
              label: '超时 ' + this.resultTimeout.toString(),
              selected: this.resultFilter === RESULT_TIMEOUT,
              onSelect: () => this.selectResultFilter(RESULT_TIMEOUT)
            })
          }
          if (this.resultUnavailable > 0) {
            DetectFilterChip({
              label: '不可用 ' + this.resultUnavailable.toString(),
              selected: this.resultFilter === RESULT_UNAVAILABLE,
              onSelect: () => this.selectResultFilter(RESULT_UNAVAILABLE)
            })
          }
        }
        .padding({ right: 16 })
      }
      .width('100%')
      .height(32)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 2, bottom: 8 })
  }

  @Builder
  ruleDisclosure() {
    Column({ space: 8 }) {
      Row() {
        Text('判定说明')
          .fontSize(12)
          .fontColor($r('app.color.text_3'))
        Blank()
        Text(this.showRules ? '收起' : '查看')
          .fontSize(12)
          .fontColor($r('app.color.brand'))
        SymbolGlyph(this.showRules ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([$r('app.color.brand')])
          .margin({ left: 2 })
      }
      .width('100%')
      .height(28)
      .onClick(() => {
        this.showRules = !this.showRules;
      })
      if (this.showRules) {
        Text('预检通过：L1 预检成功，未验证完整阅读链路。完整检测的可用：搜索、详情、目录、正文均通过。' +
          '无结果：探测词未命中，源未必失效。超时：本次请求超时，可能是瞬时问题。' +
          '不可用：链路失败（网络、解析或规则缺失等）。无结果和超时不参与批量清理。')
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 4 })
  }

  @Builder
  resultList() {
    Stack() {
      List({ scroller: this.listScroller }) {
        LazyForEach(this.dataSource, (source: SourceRow) => {
          ListItem() {
            SourceManageRow({
              source: source,
              detectMode: this.mode,
              onDetail: (row: SourceRow) => this.onDetail(row),
              onToggle: (row: SourceRow, on: boolean) => this.onToggle(row, on),
              onDelete: (row: SourceRow) => this.onDelete(row)
            })
          }
        }, (source: SourceRow) => 'detect_' + source.id.toString() + '#' + (source.enabled ? '1' : '0') +
          '#' + source.detectState + '#' + source.respondMs.toString())
      }
      .width('100%')
      .height('100%')
      .divider({
        strokeWidth: 1,
        color: $r('app.color.divider'),
        startMargin: 16
      })
      .cachedCount(8)
      .scrollBar(BarState.Off)
      .visibility(this.visibleCount === 0 ? Visibility.Hidden : Visibility.Visible)

      if (this.visibleCount === 0) {
        Column({ space: 8 }) {
          Text(this.rows.length === 0 ? '还没有书源' : '没有匹配的检测结果')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_1'))
          Text(this.rows.length === 0 ? '先导入或恢复内置书源。' : '换个关键词或检测态筛选试试。')
            .fontSize(13)
            .fontColor($r('app.color.text_4'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_page'))
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  batchActions() {
    Row({ space: 10 }) {
      Button('关闭不可用 ' + this.resultUnavailable.toString())
        .layoutWeight(1)
        .height(40)
        .fontSize(13)
        .fontColor($r('app.color.text_2'))
        .backgroundColor($r('app.color.bg_pill'))
        .borderRadius(20)
        .enabled(this.status !== DETECT_STATUS_RUNNING && !this.launching && this.unavailableIds.length > 0)
        .onClick(() => this.onDisableUnavailable(this.unavailableIds.slice()))
      Button('删除不可用 ' + this.resultUnavailable.toString())
        .layoutWeight(1)
        .height(40)
        .fontSize(13)
        .fontColor($r('app.color.warning'))
        .backgroundColor($r('app.color.bg_pill'))
        .borderRadius(20)
        .enabled(this.status !== DETECT_STATUS_RUNNING && !this.launching && this.unavailableIds.length > 0)
        .onClick(() => this.onDeleteUnavailable(this.unavailableIds.slice()))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 8 })
  }

  build() {
    Column() {
      this.rangeBar()
      this.jobCard()
      this.resultHeader()
      this.resultList()
      this.ruleDisclosure()
      if (this.resultUnavailable > 0) {
        this.batchActions()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}

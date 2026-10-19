import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import BuildProfile from 'BuildProfile';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource, ExcludedSource, GateResult } from '../engine/types';
import { loadBundled } from '../model/SourceRepository';
import {
  exportAll,
  getSource,
  listRows,
  remove,
  replaceAll,
  setEnabled,
  SourceRow,
  upsertMany
} from '../model/SourceStore';
import {
  logT16Ready,
  measureT16Ready,
  restoreT16Backup,
  seedT16Sources,
  t16MarkerPhase
} from '../model/SourceStoreBench';
import { T16ReadyResult, T16RestoreResult, T16SeedResult } from '../model/SourceStoreBenchTypes';
import { ensureSourceStore } from '../model/SourceStoreMigration';
import { SegmentedCell } from '../components/ListCells';
import { DetectPanel } from '../components/DetectPanel';
import {
  SourceManageRow,
  sourceRowMatchesQuery,
  sortSourceRowsForManage
} from '../components/SourceRows';
import {
  SourceDetailData,
  SourceDetailPanel
} from '../components/SourceDetailPanel';
import { BottomDrawer } from '../ui/common/BottomDrawer';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';
import { DEFAULT_DETECT_KEYWORD } from '../common/Const';
import {
  DETECT_BACKGROUND_INACTIVE,
  DetectJobRunner
} from '../model/DetectJobRunner';
import {
  DETECT_MODE_FULL,
  DETECT_MODE_PROBE,
  DETECT_STATUS_CANCELLED,
  DETECT_STATUS_DONE,
  DETECT_STATUS_FAILED,
  DETECT_STATUS_RUNNING
} from '../model/DetectJob';

const SEARCH_DEBOUNCE_MS: number = 150;
const SOURCE_FILTER_ALL: number = 0;
const SOURCE_FILTER_ENABLED: number = 1;
const SOURCE_FILTER_DISABLED: number = 2;
const SOURCE_FILTER_UNTESTED: number = 3;
const SOURCE_FILTER_FAILED: number = 4;

function detailPad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

function formatSourceDetectAt(value: number): string {
  if (value <= 0) {
    return '—';
  }
  const date: Date = new Date(value);
  return date.getFullYear().toString() + '-' + detailPad2(date.getMonth() + 1) + '-' +
    detailPad2(date.getDate()) + ' ' + detailPad2(date.getHours()) + ':' +
    detailPad2(date.getMinutes()) + ':' + detailPad2(date.getSeconds());
}

function formatSourceRule(rule: object | undefined): string {
  if (rule === undefined) {
    return '未配置';
  }
  const value: string | undefined = JSON.stringify(rule, null, 2);
  return value === undefined ? '未配置' : value;
}

/** Build the immutable presentation snapshot outside ArkUI's build path. */
function buildSourceDetail(row: SourceRow, source: BookSource): SourceDetailData {
  const name: string = row.name.length > 0 ? row.name : source.bookSourceName;
  return {
    id: row.id,
    name: name.length > 0 ? name : row.url,
    url: row.url,
    group: row.group.length > 0 ? row.group : '默认',
    enabled: row.enabled,
    detectState: row.detectState,
    respondMs: row.respondMs,
    detectAt: formatSourceDetectAt(row.detectAt),
    rules: [
      { label: '搜索规则', value: formatSourceRule(source.ruleSearch) },
      { label: '详情规则', value: formatSourceRule(source.ruleBookInfo) },
      { label: '目录规则', value: formatSourceRule(source.ruleToc) },
      { label: '正文规则', value: formatSourceRule(source.ruleContent) }
    ]
  };
}

function reasonLabel(reason: string): string {
  if (reason === 'needs_js') {
    return '需 JS';
  }
  if (reason === 'needs_login') {
    return '需登录';
  }
  if (reason === 'non_text') {
    return '非文字';
  }
  if (reason === 'disabled') {
    return '已禁用';
  }
  if (reason === 'bad_url') {
    return '地址无效';
  }
  if (reason === 'no_capability') {
    return '无搜索能力';
  }
  if (reason === 'no_search_rule') {
    return '缺搜索规则';
  }
  if (reason === 'no_toc_rule') {
    return '缺目录规则';
  }
  if (reason === 'no_content_rule') {
    return '缺正文规则';
  }
  return reason;
}

class SourceManageDataSource implements IDataSource {
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
struct ManageFilterChip {
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
      .onClick(() => this.onSelect())
  }
}

@ComponentV2
export struct BookSourceManagePage {
  @Local rows: SourceRow[] = [];
  @Local activeSegment: number = 0;
  @Local sourceQuery: string = '';
  @Local sourceAppliedQuery: string = '';
  @Local sourceFilter: number = SOURCE_FILTER_ENABLED;
  @Local sourceGroup: string | undefined = undefined;
  @Local sourceGroups: string[] = [];
  @Local sourceChipTotal: number = 0;
  @Local sourceChipEnabled: number = 0;
  @Local sourceChipDisabled: number = 0;
  @Local sourceChipUntested: number = 0;
  @Local sourceChipFailed: number = 0;
  @Local sourceListCount: number = 0;
  @Local enabledRows: number = 0;
  @Local totalRows: number = 0;
  @Local summary: string = '';
  @Local excludedSummary: string = '';
  @Local excluded: ExcludedSource[] = [];
  @Local showExcluded: boolean = false;
  @Local showUrl: boolean = false;
  @Local urlInput: string = '';
  @Local busy: boolean = false;
  @Local runner: DetectJobRunner = DetectJobRunner.instance();
  @Local detectMode: string = DETECT_MODE_FULL;
  @Local detectClockNow: number = Date.now();
  @Local detectLaunching: boolean = false;
  @Local detectCanResume: boolean = false;
  @Local detectBackgroundState: string = DETECT_BACKGROUND_INACTIVE;
  @Local jobOkCount: number = 0;
  @Local jobUnavailableCount: number = 0;
  @Local statusVisible: boolean = false;
  @Local selectedSource: SourceRow | undefined = undefined;
  @Local sourceDetail: SourceDetailData | undefined = undefined;
  @Local sourceDetailLoading: boolean = false;
  @Local sourceDetailFailed: boolean = false;
  @Event onOpenDebugger: () => void = () => {};
  private pageStartedAt: number = 0;
  private t16Pending: boolean = false;
  private t16MeasureStarted: boolean = false;
  private detectRestoreStarted: boolean = false;
  private sourceDs: SourceManageDataSource = new SourceManageDataSource();
  private sourceScroller: Scroller = new Scroller();
  private sourceDebounceId: number = -1;
  private sourceDetailRequest: number = 0;
  private detectClockId: number = -1;

  @Monitor('runner.updatedAt', 'runner.status')
  onDetectJobChanged(): void {
    this.syncDetectJobView();
    this.reload();
  }

  aboutToAppear(): void {
    this.activeSegment = 0;
    this.pageStartedAt = Date.now();
    this.detectClockNow = this.pageStartedAt;
    this.startDetectClock();
    this.preparePage();
  }

  aboutToDisappear(): void {
    if (this.sourceDebounceId >= 0) {
      clearTimeout(this.sourceDebounceId);
      this.sourceDebounceId = -1;
    }
    if (this.detectClockId >= 0) {
      clearInterval(this.detectClockId);
      this.detectClockId = -1;
    }
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private startDetectClock(): void {
    if (this.detectClockId >= 0) {
      clearInterval(this.detectClockId);
    }
    this.detectClockId = setInterval((): void => {
      this.detectClockNow = Date.now();
      this.detectBackgroundState = this.runner.runtimeBackgroundState();
      this.detectCanResume = this.runner.canResume();
    }, 1000);
  }

  private syncDetectJobView(): void {
    this.detectMode = this.runner.mode === DETECT_MODE_PROBE ? DETECT_MODE_PROBE : DETECT_MODE_FULL;
    this.detectCanResume = this.runner.canResume();
    this.detectBackgroundState = this.runner.runtimeBackgroundState();
  }

  private async reload(): Promise<void> {
    const ctx = this.ctx();
    if (ctx === undefined) {
      return;
    }
    try {
      await ensureSourceStore(ctx);
      const next: SourceRow[] = await listRows();
      this.rows = next;
      this.totalRows = next.length;
      this.enabledRows = this.countEnabled(next);
      this.sourceGroups = this.collectGroups(next);
      this.resetStaleGroups();
      this.refreshSourceProjection();
      this.refreshJobCounts();
    } catch (err) {
      this.rows = [];
      this.sourceGroups = [];
      this.totalRows = 0;
      this.enabledRows = 0;
      this.refreshSourceProjection();
      this.refreshJobCounts();
    }
  }

  private refreshJobCounts(): void {
    let ok: number = 0;
    let unavailable: number = 0;
    for (const row of this.rows) {
      if (row.detectState === 'ok') {
        ok += 1;
      } else if (row.detectState === 'unavailable') {
        unavailable += 1;
      }
    }
    this.jobOkCount = ok;
    this.jobUnavailableCount = unavailable;
  }

  private countEnabled(rows: SourceRow[]): number {
    let count: number = 0;
    for (const row of rows) {
      if (row.enabled) {
        count += 1;
      }
    }
    return count;
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
    groups.sort((a: string, b: string): number => {
      const left: string = a.length > 0 ? a : '默认';
      const right: string = b.length > 0 ? b : '默认';
      return left < right ? -1 : (left > right ? 1 : 0);
    });
    return groups;
  }

  private resetStaleGroups(): void {
    if (this.sourceGroup !== undefined && this.sourceGroups.indexOf(this.sourceGroup) < 0) {
      this.sourceGroup = undefined;
    }
  }

  private contextRows(rows: SourceRow[], query: string, group: string | undefined): SourceRow[] {
    const out: SourceRow[] = [];
    for (const row of rows) {
      if (!sourceRowMatchesQuery(row, query)) {
        continue;
      }
      if (group !== undefined && row.group.trim() !== group) {
        continue;
      }
      out.push(row);
    }
    return out;
  }

  private sourceFilterMatches(row: SourceRow): boolean {
    if (this.sourceFilter === SOURCE_FILTER_ENABLED) {
      return row.enabled;
    }
    if (this.sourceFilter === SOURCE_FILTER_DISABLED) {
      return !row.enabled;
    }
    if (this.sourceFilter === SOURCE_FILTER_UNTESTED) {
      return row.detectState.length === 0;
    }
    if (this.sourceFilter === SOURCE_FILTER_FAILED) {
      return row.detectState === 'unavailable';
    }
    return true;
  }

  private refreshSourceProjection(): void {
    const context: SourceRow[] = this.contextRows(this.rows, this.sourceAppliedQuery, this.sourceGroup);
    let enabled: number = 0;
    let disabled: number = 0;
    let untested: number = 0;
    let failed: number = 0;
    for (const row of context) {
      if (row.enabled) {
        enabled += 1;
      } else {
        disabled += 1;
      }
      if (row.detectState.length === 0) {
        untested += 1;
      } else if (row.detectState === 'unavailable') {
        failed += 1;
      }
    }
    this.sourceChipTotal = context.length;
    this.sourceChipEnabled = enabled;
    this.sourceChipDisabled = disabled;
    this.sourceChipUntested = untested;
    this.sourceChipFailed = failed;
    if ((this.sourceFilter === SOURCE_FILTER_DISABLED && disabled === 0) ||
      (this.sourceFilter === SOURCE_FILTER_UNTESTED && untested === 0) ||
      (this.sourceFilter === SOURCE_FILTER_FAILED && failed === 0)) {
      this.sourceFilter = SOURCE_FILTER_ALL;
    }

    const visible: SourceRow[] = [];
    for (const row of context) {
      if (this.sourceFilterMatches(row)) {
        visible.push(row);
      }
    }
    const next: SourceRow[] = sortSourceRowsForManage(visible);
    this.sourceDs.setItems(next);
    this.sourceListCount = next.length;
  }

  private scheduleSourceQuery(value: string): void {
    this.sourceQuery = value;
    if (this.sourceDebounceId >= 0) {
      clearTimeout(this.sourceDebounceId);
    }
    this.sourceDebounceId = setTimeout((): void => {
      this.sourceDebounceId = -1;
      this.sourceAppliedQuery = value;
      this.refreshSourceProjection();
    }, SEARCH_DEBOUNCE_MS);
  }

  private clearSourceQuery(): void {
    if (this.sourceDebounceId >= 0) {
      clearTimeout(this.sourceDebounceId);
      this.sourceDebounceId = -1;
    }
    this.sourceQuery = '';
    this.sourceAppliedQuery = '';
    this.refreshSourceProjection();
  }

  private selectSourceFilter(index: number): void {
    this.sourceFilter = index;
    this.refreshSourceProjection();
  }

  private selectSourceGroup(group: string | undefined): void {
    this.sourceGroup = group;
    this.refreshSourceProjection();
  }

  private clearSourceCriteria(): void {
    if (this.sourceDebounceId >= 0) {
      clearTimeout(this.sourceDebounceId);
      this.sourceDebounceId = -1;
    }
    this.sourceQuery = '';
    this.sourceAppliedQuery = '';
    this.sourceFilter = SOURCE_FILTER_ALL;
    this.sourceGroup = undefined;
    this.refreshSourceProjection();
  }

  private async preparePage(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    const phase: string = t16MarkerPhase(ctx);
    if (phase === 'seeded') {
      this.t16Pending = true;
      this.summary = 'T1.6 性能测量将在首帧后开始';
      return;
    }
    if (phase === 'seeding') {
      try {
        const restored: T16RestoreResult = await restoreT16Backup(ctx);
        await this.reload();
        this.summary = `已从造数中断恢复 ${restored.rows} 条书源`;
      } catch (err) {
        this.summary = 'T1.6 中断恢复失败，请查看 hilog';
      }
      return;
    }
    await this.reload();
    if (!this.detectRestoreStarted) {
      this.detectRestoreStarted = true;
      const previousStatus: string = this.runner.status;
      const previousUpdatedAt: number = this.runner.updatedAt;
      await this.runner.restore(ctx);
      this.syncDetectJobView();
      if (this.runner.status !== previousStatus || this.runner.updatedAt !== previousUpdatedAt) {
        await this.reload();
      }
    }
  }

  private async runT16Ready(): Promise<void> {
    if (!this.t16Pending || this.t16MeasureStarted) {
      return;
    }
    this.t16MeasureStarted = true;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      this.t16MeasureStarted = false;
      return;
    }
    const firstFrameMs: number = Date.now() - this.pageStartedAt;
    try {
      const ready: T16ReadyResult = await measureT16Ready(ctx);
      logT16Ready(ready, firstFrameMs, Date.now() - this.pageStartedAt);
      const restored: T16RestoreResult = await restoreT16Backup(ctx);
      this.t16Pending = false;
      await this.reload();
      this.summary = `T1.6 实测完成，已恢复 ${restored.rows} 条书源`;
    } catch (err) {
      this.summary = 'T1.6 首帧测量失败，请查看 hilog';
    }
  }

  private normalize(raw: string): BookSource[] {
    try {
      const parsed: object = JSON.parse(raw) as object;
      if (parsed === null) {
        return [];
      }
      if (Array.isArray(parsed)) {
        return parsed as BookSource[];
      }
      const single: BookSource = parsed as BookSource;
      if (single.bookSourceUrl !== undefined) {
        return [single];
      }
      return [];
    } catch (err) {
      return [];
    }
  }

  private async applyGate(list: BookSource[]): Promise<void> {
    if (list.length === 0) {
      this.summary = '未解析到有效书源';
      this.excluded = [];
      return;
    }
    const result: GateResult = bookEngine.gate(list);
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      this.summary = '书源保存失败';
      return;
    }
    try {
      await ensureSourceStore(ctx);
      await upsertMany(result.eligible);
      await this.reload();
    } catch (err) {
      this.summary = '书源保存失败';
      return;
    }
    this.excluded = result.excluded;
    this.excludedSummary = this.reasonCounts();
    this.showExcluded = false;
    // "规则通过" not "成功": the import gate only checks rule shape, it does
    // not prove the source works at runtime (use 检测可用性 for that).
    this.summary = `规则通过 ${result.eligible.length} / 规则排除 ${result.excluded.length}`;
  }

  private async importText(text: string): Promise<void> {
    await this.applyGate(this.normalize(text));
  }

  private async importFromFile(): Promise<void> {
    const ctx = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.busy = true;
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json', '.txt'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
      await this.importText(text);
    } catch (err) {
      this.summary = '文件读取失败';
    } finally {
      this.busy = false;
    }
  }

  private async importFromUrl(): Promise<void> {
    const url: string = this.urlInput.trim();
    if (url.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const text: string = await bookEngine.fetchText(url);
      await this.importText(text);
      this.showUrl = false;
      this.urlInput = '';
    } catch (err) {
      this.summary = 'URL 下载失败';
    } finally {
      this.busy = false;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private dateStr(): string {
    const date: Date = new Date();
    const monthNumber: number = date.getMonth() + 1;
    const month: string = monthNumber < 10 ? '0' + monthNumber.toString() : monthNumber.toString();
    const dayNumber: number = date.getDate();
    const day: string = dayNumber < 10 ? '0' + dayNumber.toString() : dayNumber.toString();
    return date.getFullYear().toString() + '-' + month + '-' + day;
  }

  private async exportSources(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.busy = true;
    try {
      const sources: BookSource[] = await exportAll();
      const json: string = JSON.stringify(sources, null, 2);
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = ['book-sources_' + this.dateStr() + '.json'];
      options.fileSuffixChoices = ['JSON|.json'];
      const uris: string[] = await savePicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(
        uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, json);
      } finally {
        fileIo.closeSync(file);
      }
      this.summary = `已导出 ${sources.length} 条书源`;
      this.excluded = [];
      this.excludedSummary = '';
    } catch (err) {
      this.summary = '导出书源失败';
    } finally {
      this.busy = false;
    }
  }

  private async removeSource(row: SourceRow): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    try {
      await ensureSourceStore(ctx);
      await remove(row.id);
      const next: SourceRow[] = this.rows.filter((source: SourceRow) => source.id !== row.id);
      this.rows = next;
      this.totalRows = next.length;
      this.enabledRows = this.countEnabled(next);
      this.sourceGroups = this.collectGroups(next);
      this.resetStaleGroups();
      this.refreshSourceProjection();
      this.refreshJobCounts();
      if (this.selectedSource !== undefined && this.selectedSource.id === row.id) {
        this.statusVisible = false;
        this.selectedSource = undefined;
        this.sourceDetail = undefined;
        this.sourceDetailLoading = false;
        this.sourceDetailFailed = false;
        this.sourceDetailRequest += 1;
      }
    } catch (err) {
      this.summary = '删除失败';
    }
  }

  private confirmRemoveSource(row: SourceRow): void {
    const name: string = row.name.length > 0 ? row.name : row.url;
    this.getUIContext().showAlertDialog({
      title: '删除书源',
      message: '确定删除「' + name + '」吗？删除后不可恢复。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.removeSource(row);
        }
      }
    });
  }

  private async toggleSource(row: SourceRow, on: boolean): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    try {
      await ensureSourceStore(ctx);
      await setEnabled(row.id, on);
      for (const source of this.rows) {
        if (source.id === row.id) {
          source.enabled = on;
          break;
        }
      }
      this.enabledRows = this.countEnabled(this.rows);
      this.refreshSourceProjection();
      this.refreshJobCounts();
      this.rows = this.rows.slice();
    } catch (err) {
      this.summary = '保存启用状态失败';
    }
  }

  private confirmT16Seed(): void {
    this.getUIContext().showAlertDialog({
      title: 'T1.6 性能造数',
      message: '将备份当前书源，再写入 filesDir/t1.6-sources.json 中的 3000 条临时书源。' +
        '造数完成后请 force-stop 重启并重新进入本页，首帧后会测量并自动恢复备份。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '开始造数',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.runT16Seed();
        }
      }
    });
  }

  private async runT16Seed(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.busy = true;
    try {
      const result: T16SeedResult = await seedT16Sources(ctx);
      this.summary = `T1.6 已造数 ${result.stats.rows} 条（备份 ${result.backupRows} 条），` +
        '请 force-stop 重启后进入本页继续测量';
    } catch (err) {
      this.summary = 'T1.6 造数失败，请查看 hilog';
    } finally {
      this.busy = false;
    }
  }

  private async resetBundled(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    let bundled: BookSource[] = [];
    try {
      bundled = loadBundled(ctx);
      if (bundled.length === 0) {
        this.summary = '读取内置书源失败';
        return;
      }
      await ensureSourceStore(ctx);
      await replaceAll(bundled, bundled.length);
      await this.reload();
    } catch (err) {
      this.summary = '恢复内置书源失败';
      return;
    }
    this.summary = `已恢复内置书源 ${bundled.length} 个`;
    this.excluded = [];
    this.excludedSummary = '';
    this.statusVisible = false;
    this.selectedSource = undefined;
    this.sourceDetail = undefined;
    this.sourceDetailLoading = false;
    this.sourceDetailFailed = false;
    this.sourceDetailRequest += 1;
  }

  private confirmResetBundled(): void {
    this.getUIContext().showAlertDialog({
      title: '替换全部书源',
      message: '将删除当前 ' + this.totalRows.toString() +
        ' 条书源，并用内置书源替换。此操作不可撤销。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '替换',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.resetBundled();
        }
      }
    });
  }

  private openSourceDetail(row: SourceRow): void {
    const request: number = this.sourceDetailRequest + 1;
    this.sourceDetailRequest = request;
    this.selectedSource = row;
    this.sourceDetail = undefined;
    this.sourceDetailLoading = true;
    this.sourceDetailFailed = false;
    this.statusVisible = true;
    this.loadSourceDetail(row, request);
  }

  private async launchDetect(mode: string, sourceIds: string[]): Promise<void> {
    if (this.detectLaunching) {
      return;
    }
    if (sourceIds.length === 0) {
      this.summary = '当前范围没有可检测的书源';
      return;
    }
    this.detectLaunching = true;
    try {
      const accepted: boolean = await this.runner.start(mode, DEFAULT_DETECT_KEYWORD, sourceIds);
      this.syncDetectJobView();
      if (accepted) {
        this.summary = '';
      } else if (this.runner.status !== DETECT_STATUS_RUNNING) {
        this.summary = '检测作业启动失败';
      }
    } finally {
      this.detectLaunching = false;
      this.syncDetectJobView();
    }
  }

  private async cancelDetect(): Promise<void> {
    if (this.detectLaunching) {
      return;
    }
    this.detectLaunching = true;
    try {
      if (!(await this.runner.cancel())) {
        this.summary = '检测作业未在运行';
      }
      this.syncDetectJobView();
    } finally {
      this.detectLaunching = false;
      this.syncDetectJobView();
    }
  }

  private async resumeDetect(): Promise<void> {
    if (this.detectLaunching) {
      return;
    }
    this.detectLaunching = true;
    try {
      if (!(await this.runner.resume())) {
        this.summary = '当前进程未保留可续跑范围，请重新开始';
      }
      this.syncDetectJobView();
    } finally {
      this.detectLaunching = false;
      this.syncDetectJobView();
    }
  }

  private detailRequestCurrent(row: SourceRow, request: number): boolean {
    return this.sourceDetailRequest === request &&
      this.selectedSource !== undefined &&
      this.selectedSource.id === row.id;
  }

  private async loadSourceDetail(row: SourceRow, request: number): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      if (this.detailRequestCurrent(row, request)) {
        this.sourceDetailLoading = false;
        this.sourceDetailFailed = true;
      }
      return;
    }
    try {
      await ensureSourceStore(ctx);
      const source: BookSource | undefined = await getSource(row.id);
      if (!this.detailRequestCurrent(row, request)) {
        return;
      }
      if (source === undefined) {
        this.sourceDetailFailed = true;
      } else {
        this.sourceDetail = buildSourceDetail(row, source);
      }
    } catch (err) {
      if (this.detailRequestCurrent(row, request)) {
        this.sourceDetailFailed = true;
      }
    } finally {
      if (this.detailRequestCurrent(row, request)) {
        this.sourceDetailLoading = false;
      }
    }
  }

  private sourceRowKey(source: SourceRow): string {
    return source.id.toString() + '#' + (source.enabled ? '1' : '0') + '#' +
      source.detectState + '#' + source.respondMs.toString();
  }

  private groupLabel(group: string | undefined): string {
    if (group === undefined) {
      return '分组';
    }
    return '分组 · ' + (group.length > 0 ? group : '默认');
  }

  private groupMenuItems(groups: string[], onSelect: (next: string | undefined) => void): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: '全部分组',
        action: () => onSelect(undefined)
      }
    ];
    for (const item of groups) {
      items.push({
        value: item.length > 0 ? item : '默认',
        action: () => onSelect(item)
      });
    }
    return items;
  }

  private sourceGroupMenuItems(): MenuElement[] {
    return this.groupMenuItems(this.sourceGroups,
      (next: string | undefined) => this.selectSourceGroup(next));
  }

  private addMenuItems(): MenuElement[] {
    return [
      {
        value: '从文件导入',
        action: () => {
          this.importFromFile();
        }
      },
      {
        value: '从链接导入',
        action: () => {
          this.showUrl = !this.showUrl;
        }
      },
      {
        value: '规则调试器',
        action: () => this.onOpenDebugger()
      }
    ];
  }

  private moreMenuItems(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: '导出书源',
        action: () => {
          this.exportSources();
        }
      },
      {
        value: '恢复内置',
        action: () => {
          this.confirmResetBundled();
        }
      }
    ];
    if (BuildProfile.DEBUG) {
      items.push({
        value: 'T1.6 性能造数（3000）',
        action: () => this.confirmT16Seed()
      });
    }
    return items;
  }

  private uniqueSourceIds(sourceIds: number[]): Set<number> {
    const ids: Set<number> = new Set<number>();
    for (const id of sourceIds) {
      if (Number.isInteger(id) && id > 0) {
        ids.add(id);
      }
    }
    return ids;
  }

  private matchingUnavailableRows(sourceIds: number[]): SourceRow[] {
    const ids: Set<number> = this.uniqueSourceIds(sourceIds);
    const matched: SourceRow[] = [];
    for (const row of this.rows) {
      if (ids.has(row.id) && row.detectState === 'unavailable') {
        matched.push(row);
      }
    }
    return matched;
  }

  private confirmDisableUnavailable(sourceIds: number[]): void {
    const rows: SourceRow[] = this.matchingUnavailableRows(sourceIds);
    let enabled: number = 0;
    for (const row of rows) {
      if (row.enabled) {
        enabled += 1;
      }
    }
    if (enabled === 0) {
      this.summary = '不可用源均已关闭';
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '关闭不可用书源',
      message: '将关闭 ' + enabled.toString() + ' 个不可用书源，书源数据会保留。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '关闭',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.disableUnavailable(sourceIds);
        }
      }
    });
  }

  private async disableUnavailable(sourceIds: number[]): Promise<void> {
    const ids: Set<number> = this.uniqueSourceIds(sourceIds);
    if (ids.size === 0) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    let changed: number = 0;
    try {
      await ensureSourceStore(ctx);
      for (const row of this.rows) {
        if (ids.has(row.id) && row.detectState === 'unavailable' && row.enabled) {
          await setEnabled(row.id, false);
          changed += 1;
        }
      }
      await this.reload();
    } catch (err) {
      this.summary = '关闭不可用源失败';
      return;
    }
    this.summary = changed > 0 ? `已关闭 ${changed} 个不可用源` : '不可用源均已关闭';
  }

  private confirmDeleteUnavailable(sourceIds: number[]): void {
    const rows: SourceRow[] = this.matchingUnavailableRows(sourceIds);
    if (rows.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除不可用书源',
      message: '确定删除 ' + rows.length.toString() + ' 个不可用书源吗？删除后不可恢复。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.deleteUnavailable(sourceIds);
        }
      }
    });
  }

  private async deleteUnavailable(sourceIds: number[]): Promise<void> {
    const ids: Set<number> = this.uniqueSourceIds(sourceIds);
    if (ids.size === 0) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    let removed: number = 0;
    try {
      await ensureSourceStore(ctx);
      for (const row of this.rows) {
        if (ids.has(row.id) && row.detectState === 'unavailable') {
          await remove(row.id);
          removed += 1;
        }
      }
      await this.reload();
    } catch (err) {
      this.summary = '删除不可用源失败';
      return;
    }
    this.summary = `已删除 ${removed} 个不可用源`;
  }

  private reasonCounts(): string {
    const counts: Map<string, number> = new Map<string, number>();
    for (const e of this.excluded) {
      const label: string = reasonLabel(e.reason);
      const prev: number = counts.get(label) ?? 0;
      counts.set(label, prev + 1);
    }
    const parts: string[] = [];
    counts.forEach((count: number, label: string) => {
      parts.push(`${label} ${count}`);
    });
    return parts.join('、');
  }

  private jobModeLabel(): string {
    return this.runner.mode === DETECT_MODE_PROBE ? '预检' : '完整检测';
  }

  private jobBarTitle(): string {
    if (this.runner.status === DETECT_STATUS_RUNNING) {
      return this.runner.done.toString() + '/' + this.runner.total.toString() + ' · ' + this.jobModeLabel();
    }
    if (this.runner.status === DETECT_STATUS_DONE) {
      return this.runner.mode === DETECT_MODE_PROBE ? '预检完成' : '检测完成';
    }
    if (this.runner.status === DETECT_STATUS_CANCELLED) {
      return '已取消';
    }
    if (this.runner.status === DETECT_STATUS_FAILED) {
      return '检测失败';
    }
    return '检测书源…';
  }

  private jobBarMeta(): string {
    if (this.runner.status === DETECT_STATUS_RUNNING) {
      return '检测中 · 每批 ' + this.runner.batchSize.toString() + ' 个';
    }
    if (this.runner.status === DETECT_STATUS_DONE) {
      const okLabel: string = this.runner.mode === DETECT_MODE_PROBE ? '预检通过' : '可用';
      return okLabel + ' ' + this.jobOkCount.toString() + ' / 不可用 ' +
        this.jobUnavailableCount.toString();
    }
    if (this.runner.status === DETECT_STATUS_CANCELLED ||
      this.runner.status === DETECT_STATUS_FAILED) {
      return '已测 ' + this.runner.done.toString() + ' / ' + this.runner.total.toString();
    }
    return '选择范围后开始检测';
  }

  private jobBarDotColor(): ResourceColor {
    if (this.runner.status === DETECT_STATUS_RUNNING) {
      return $r('app.color.info');
    }
    if (this.runner.status === DETECT_STATUS_FAILED) {
      return $r('app.color.warning');
    }
    if (this.runner.status === DETECT_STATUS_DONE) {
      return $r('app.color.brand');
    }
    return $r('app.color.text_4');
  }

  @Builder
  segmentHeader() {
    Row({ space: 4 }) {
      Column() {
        SegmentedCell({
          options: ['书源', '检测'],
          selected: this.activeSegment,
          onSelect: (index: number) => {
            this.activeSegment = index;
          }
        })
      }
      .layoutWeight(1)

      Row() {
        Text('+')
          .fontSize(28)
          .fontWeight(FontWeight.Lighter)
          .fontColor($r('app.color.text_2'))
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .accessibilityText('添加书源')
      .accessibilityLevel('yes')
      .bindMenu(this.addMenuItems())

      MoreMenuButton({
        items: this.moreMenuItems(),
        label: '更多书源操作'
      })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  urlImportBar() {
    Row() {
      TextInput({ placeholder: 'https://... 书源 JSON 地址', text: this.urlInput })
        .layoutWeight(1)
        .height(44)
        .fontSize(14)
        .fontColor($r('app.color.text_1'))
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(22)
        .onChange((value: string) => {
          this.urlInput = value;
        })
      Button('导入')
        .height(44)
        .fontSize(15)
        .fontColor($r('app.color.on_brand'))
        .backgroundColor($r('app.color.brand'))
        .borderRadius(22)
        .margin({ left: 10 })
        .onClick(() => {
          this.importFromUrl();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
  }

  @Builder
  summaryBanner() {
    Column({ space: 6 }) {
      Text(this.summary)
        .fontSize(13)
        .fontColor($r('app.color.text_2'))
        .width('100%')
      if (this.excludedSummary.length > 0) {
        Text(this.excludedSummary)
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
          .width('100%')
        Text(this.showExcluded ? '收起明细' : '查看排除明细')
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            this.showExcluded = !this.showExcluded;
          })
        if (this.showExcluded) {
          Scroll() {
            Column() {
              ForEach(this.excluded, (item: ExcludedSource) => {
                Row() {
                  Text(item.bookSourceName.length > 0 ? item.bookSourceName : item.bookSourceUrl)
                    .fontSize(12)
                    .fontColor($r('app.color.text_2'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(reasonLabel(item.reason))
                    .fontSize(12)
                    .fontColor($r('app.color.warning'))
                }
                .width('100%')
                .padding({ top: 3, bottom: 3 })
              }, (item: ExcludedSource) => item.bookSourceUrl + '_' + item.reason)
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 108 })
          .scrollBar(BarState.Off)
        }
      }
    }
    .width('100%')
    .padding(12)
    .margin({ left: 16, right: 16, bottom: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  @Builder
  sourceSearchBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([$r('app.color.text_4')])
      TextInput({ text: this.sourceQuery, placeholder: '搜索名称 / 地址 / 分组' })
        .layoutWeight(1)
        .height(44)
        .fontSize(15)
        .fontColor($r('app.color.text_1'))
        .placeholderColor($r('app.color.text_5'))
        .backgroundColor(Color.Transparent)
        .padding({ left: 8, right: 0 })
        .onChange((value: string) => {
          this.scheduleSourceQuery(value);
        })
      if (this.sourceQuery.length > 0) {
        Text('✕')
          .fontSize(14)
          .fontColor($r('app.color.text_4'))
          .padding({ left: 6, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.clearSourceQuery();
          })
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(22)
  }

  @Builder
  emptyState() {
    Column({ space: 10 }) {
      Text(this.totalRows === 0 ? '还没有书源' : '没有匹配的书源')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))
      Text(this.totalRows === 0 ? '导入书源，或恢复内置书源。' : '换个关键词、筛选或分组试试。')
        .fontSize(13)
        .fontColor($r('app.color.text_4'))
      Button(this.totalRows === 0 ? '恢复内置' : '清除搜索和筛选')
        .height(36)
        .fontSize(14)
        .fontColor(this.totalRows === 0 ? $r('app.color.on_brand') : $r('app.color.brand'))
        .backgroundColor(this.totalRows === 0 ? $r('app.color.brand') : $r('app.color.bg_pill'))
        .borderRadius(18)
        .margin({ top: 4 })
        .onClick(() => {
          if (this.totalRows === 0) {
            this.confirmResetBundled();
          } else {
            this.clearSourceCriteria();
          }
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  sourceSegment() {
    Column() {
      Column({ space: 8 }) {
        this.sourceSearchBar()
        Scroll() {
          Row({ space: 8 }) {
            ManageFilterChip({
              label: '全部 ' + this.sourceChipTotal.toString(),
              selected: this.sourceFilter === SOURCE_FILTER_ALL,
              onSelect: () => this.selectSourceFilter(SOURCE_FILTER_ALL)
            })
            ManageFilterChip({
              label: '启用 ' + this.sourceChipEnabled.toString(),
              selected: this.sourceFilter === SOURCE_FILTER_ENABLED,
              onSelect: () => this.selectSourceFilter(SOURCE_FILTER_ENABLED)
            })
            if (this.sourceChipDisabled > 0) {
              ManageFilterChip({
                label: '停用 ' + this.sourceChipDisabled.toString(),
                selected: this.sourceFilter === SOURCE_FILTER_DISABLED,
                onSelect: () => this.selectSourceFilter(SOURCE_FILTER_DISABLED)
              })
            }
            if (this.sourceChipUntested > 0) {
              ManageFilterChip({
                label: '未测 ' + this.sourceChipUntested.toString(),
                selected: this.sourceFilter === SOURCE_FILTER_UNTESTED,
                onSelect: () => this.selectSourceFilter(SOURCE_FILTER_UNTESTED)
              })
            }
            if (this.sourceChipFailed > 0) {
              ManageFilterChip({
                label: '失败 ' + this.sourceChipFailed.toString(),
                selected: this.sourceFilter === SOURCE_FILTER_FAILED,
                onSelect: () => this.selectSourceFilter(SOURCE_FILTER_FAILED)
              })
            }
            Text(this.groupLabel(this.sourceGroup))
              .fontSize(13)
              .fontColor(this.sourceGroup === undefined ? $r('app.color.text_2') : $r('app.color.brand'))
              .backgroundColor($r('app.color.bg_pill'))
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(16)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .bindMenu(this.sourceGroupMenuItems())
          }
          .padding({ right: 16 })
        }
        .width('100%')
        .height(32)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      Row() {
        Text(`显示 ${this.sourceListCount} / ${this.totalRows} 条 · ${this.enabledRows} 启用`)
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
      }
      .width('100%')
      .height(32)
      .padding({ left: 16, right: 16 })

      Stack() {
        List({ scroller: this.sourceScroller }) {
          LazyForEach(this.sourceDs, (source: SourceRow) => {
            ListItem() {
              SourceManageRow({
                source: source,
                detectMode: this.detectMode,
                onDetail: (source: SourceRow) => {
                  this.openSourceDetail(source);
                },
                onToggle: (source: SourceRow, on: boolean) => {
                  this.toggleSource(source, on);
                },
                onDelete: (source: SourceRow) => {
                  this.confirmRemoveSource(source);
                }
              })
            }
          }, (source: SourceRow) => this.sourceRowKey(source))
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
        .visibility(this.sourceListCount === 0 ? Visibility.Hidden : Visibility.Visible)

        if (this.sourceListCount === 0) {
          this.emptyState()
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .visibility(this.activeSegment === 0 ? Visibility.Visible : Visibility.Hidden)
  }

  @Builder
  detectSegment() {
    DetectPanel({
      rows: this.rows,
      status: this.runner.status,
      mode: this.runner.mode,
      total: this.runner.total,
      done: this.runner.done,
      startedAt: this.runner.startedAt,
      updatedAt: this.runner.updatedAt,
      message: this.runner.message,
      backgroundState: this.detectBackgroundState,
      clockNow: this.detectClockNow,
      launching: this.detectLaunching,
      canResume: this.detectCanResume,
      onStart: (mode: string, sourceIds: string[]) => {
        this.launchDetect(mode, sourceIds);
      },
      onCancel: () => {
        this.cancelDetect();
      },
      onResume: () => {
        this.resumeDetect();
      },
      onDetail: (source: SourceRow) => {
        this.openSourceDetail(source);
      },
      onToggle: (source: SourceRow, on: boolean) => {
        this.toggleSource(source, on);
      },
      onDelete: (source: SourceRow) => {
        this.confirmRemoveSource(source);
      },
      onDisableUnavailable: (sourceIds: number[]) => {
        this.confirmDisableUnavailable(sourceIds);
      },
      onDeleteUnavailable: (sourceIds: number[]) => {
        this.confirmDeleteUnavailable(sourceIds);
      }
    })
    .width('100%')
    .height('100%')
    .visibility(this.activeSegment === 1 ? Visibility.Visible : Visibility.Hidden)
  }

  @Builder
  jobBar() {
    Row({ space: 10 }) {
      Row({ space: 8 }) {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor(this.jobBarDotColor())
        Column({ space: 4 }) {
          Text(this.jobBarTitle())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_2'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.runner.status === DETECT_STATUS_RUNNING) {
            Progress({
              value: this.runner.done,
              total: this.runner.total > 0 ? this.runner.total : 1,
              type: ProgressType.Linear
            })
              .width('100%')
              .height(3)
              .color($r('app.color.brand'))
              .backgroundColor($r('app.color.bg_pill'))
          } else {
            Text(this.jobBarMeta())
              .fontSize(12)
              .fontColor($r('app.color.text_4'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .accessibilityText(this.jobBarTitle() + '，' + this.jobBarMeta())
      .accessibilityLevel('yes')
      .onClick(() => {
        this.activeSegment = 1;
      })

      if (this.runner.status === DETECT_STATUS_RUNNING) {
        Button(this.detectLaunching ? '正在停止…' : '取消')
          .height(32)
          .fontSize(13)
          .fontColor($r('app.color.text_2'))
          .backgroundColor($r('app.color.bg_pill'))
          .borderRadius(16)
          .enabled(!this.detectLaunching)
          .accessibilityText('取消检测')
          .onClick(() => {
            this.cancelDetect();
          })
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([$r('app.color.text_4')])
      }
    }
    .width('100%')
    .height(60)
    .padding({ left: 16, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
    .margin({ left: 16, right: 16, top: 6, bottom: 8 })
  }

  build() {
    Stack() {
      Column() {
        this.segmentHeader()
        if (this.showUrl) {
          this.urlImportBar()
        }
        if (this.summary.length > 0) {
          this.summaryBanner()
        }
        Stack() {
          this.sourceSegment()
          this.detectSegment()
        }
        .layoutWeight(1)
        .width('100%')
        this.jobBar()
      }
      .width('100%')
      .height('100%')
      .onAppear(() => {
        this.runT16Ready();
      })

      BottomDrawer({
        visible: this.statusVisible,
        title: '书源详情',
        sheetSize: 'large',
        mode: 'overlay',
        onClose: () => {
          this.statusVisible = false;
        }
      }) {
        if (this.selectedSource !== undefined) {
          // A mounted panel can retain stale text when the selected source changes.
          ForEach([this.selectedSource.id], (_id: number) => {
            SourceDetailPanel({
              detail: this.sourceDetail,
              detectMode: this.detectMode,
              loading: this.sourceDetailLoading,
              failed: this.sourceDetailFailed,
              onDelete: () => {
                const row: SourceRow | undefined = this.selectedSource;
                if (row !== undefined) {
                  this.confirmRemoveSource(row);
                }
              }
            })
          }, (id: number) => id.toString())
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}

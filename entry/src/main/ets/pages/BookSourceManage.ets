import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import BuildProfile from 'BuildProfile';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource, DetectResult, ExcludedSource, GateResult } from '../engine/types';
import { loadBundled } from '../model/SourceRepository';
import {
  allForEngine,
  exportAll,
  getSource,
  listRows,
  remove,
  replaceAll,
  setEnabled,
  sourceNaturalKey,
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
import { InsetDivider, SegmentedCell } from '../components/ListCells';
import {
  SourceManageRow,
  sourceRowMatchesQuery,
  sourceRowStateLabel,
  sortSourceRowsForManage
} from '../components/SourceRows';
import {
  SourceDetailData,
  SourceDetailPanel
} from '../components/SourceDetailPanel';
import { BottomDrawer } from '../ui/common/BottomDrawer';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';
import { DEFAULT_DETECT_KEYWORD } from '../common/Const';

/**
 * Detection verdict, derived from `DetectResult`. `noResult` and `timeout` are
 * deliberately kept apart from `unavailable`: a source that merely returned no
 * hits for the probe keyword (or timed out once) is not proven broken, so it is
 * excluded from the one-tap cleanup actions.
 */
type DetectState = 'ok' | 'noResult' | 'timeout' | 'unavailable';

const SEARCH_DEBOUNCE_MS: number = 150;
const SOURCE_FILTER_ALL: number = 0;
const SOURCE_FILTER_ENABLED: number = 1;
const SOURCE_FILTER_DISABLED: number = 2;
const SOURCE_FILTER_UNTESTED: number = 3;
const SOURCE_FILTER_FAILED: number = 4;
const DETECT_FILTER_ALL: number = 0;
const DETECT_FILTER_UNTESTED: number = 1;
const DETECT_FILTER_FAILED: number = 2;

function detectStateOf(result: DetectResult): DetectState {
  if (result.ok) {
    return 'ok';
  }
  if (result.stage === 'no_results') {
    return 'noResult';
  }
  if (result.stage === 'timeout') {
    return 'timeout';
  }
  return 'unavailable';
}

function detectStateLabel(state: DetectState): string {
  if (state === 'ok') {
    return '可用';
  }
  if (state === 'noResult') {
    return '无结果';
  }
  if (state === 'timeout') {
    return '超时';
  }
  return '不可用';
}

/** Map a detect `stage` (engine `FailReason` string) to a user-facing label. */
function detectStageLabel(stage: string): string {
  if (stage === 'no_results') {
    return '搜索未命中';
  }
  if (stage === 'timeout') {
    return '检测超时';
  }
  if (stage === 'network_error') {
    return '网络错误';
  }
  if (stage === 'builder_error') {
    return '无法构建搜索请求';
  }
  if (stage === 'no_book_url') {
    return '未解析到书籍地址';
  }
  if (stage === 'bookinfo_fetch') {
    return '详情页获取失败';
  }
  if (stage === 'toc_fetch') {
    return '目录页获取失败';
  }
  if (stage === 'toc_parse') {
    return '目录解析失败';
  }
  if (stage === 'no_toc_rule') {
    return '缺少目录规则';
  }
  if (stage === 'chapter_fetch') {
    return '章节页获取失败';
  }
  if (stage === 'no_content_rule') {
    return '缺少正文规则';
  }
  if (stage === 'content_empty') {
    return '正文为空';
  }
  if (stage === 'content_short') {
    return '正文过短';
  }
  if (stage === 'mismatch') {
    return '书名不一致';
  }
  if (stage === 'blocked') {
    return '被站点拦截';
  }
  if (stage === 'not_found') {
    return '页面不存在';
  }
  if (stage === 'rate_limited') {
    return '请求过于频繁';
  }
  if (stage === 'server_error') {
    return '服务器错误';
  }
  if (stage === 'http_error') {
    return 'HTTP 错误';
  }
  return stage.length > 0 ? stage : '未知错误';
}

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
  @Local detectQuery: string = '';
  @Local detectAppliedQuery: string = '';
  @Local detectFilter: number = DETECT_FILTER_ALL;
  @Local detectGroup: string | undefined = undefined;
  @Local detectGroups: string[] = [];
  @Local detectChipTotal: number = 0;
  @Local detectChipUntested: number = 0;
  @Local detectChipFailed: number = 0;
  @Local detectListCount: number = 0;
  @Local enabledRows: number = 0;
  @Local totalRows: number = 0;
  @Local jobText: string = '检测书源…';
  @Local summary: string = '';
  @Local excludedSummary: string = '';
  @Local excluded: ExcludedSource[] = [];
  @Local showExcluded: boolean = false;
  @Local showUrl: boolean = false;
  @Local urlInput: string = '';
  @Local busy: boolean = false;
  @Local detectResults: DetectResult[] = [];
  @Local statusVisible: boolean = false;
  @Local selectedSource: SourceRow | undefined = undefined;
  @Local sourceDetail: SourceDetailData | undefined = undefined;
  @Local sourceDetailLoading: boolean = false;
  @Local sourceDetailFailed: boolean = false;
  @Event onOpenDebugger: () => void = () => {};
  private pageStartedAt: number = 0;
  private t16Pending: boolean = false;
  private t16MeasureStarted: boolean = false;
  private sourceDs: SourceManageDataSource = new SourceManageDataSource();
  private detectDs: SourceManageDataSource = new SourceManageDataSource();
  private sourceScroller: Scroller = new Scroller();
  private detectScroller: Scroller = new Scroller();
  private sourceDebounceId: number = -1;
  private detectDebounceId: number = -1;
  private sourceDetailRequest: number = 0;

  aboutToAppear(): void {
    this.activeSegment = 0;
    this.pageStartedAt = Date.now();
    this.preparePage();
  }

  aboutToDisappear(): void {
    if (this.sourceDebounceId >= 0) {
      clearTimeout(this.sourceDebounceId);
      this.sourceDebounceId = -1;
    }
    if (this.detectDebounceId >= 0) {
      clearTimeout(this.detectDebounceId);
      this.detectDebounceId = -1;
    }
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
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
      this.detectGroups = this.collectGroups(next);
      this.resetStaleGroups();
      this.refreshSourceProjection();
      this.refreshDetectProjection();
    } catch (err) {
      this.rows = [];
      this.sourceGroups = [];
      this.detectGroups = [];
      this.totalRows = 0;
      this.enabledRows = 0;
      this.refreshSourceProjection();
      this.refreshDetectProjection();
    }
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
    if (this.detectGroup !== undefined && this.detectGroups.indexOf(this.detectGroup) < 0) {
      this.detectGroup = undefined;
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

  private detectFilterMatches(row: SourceRow): boolean {
    if (this.detectFilter === DETECT_FILTER_UNTESTED) {
      return row.detectState.length === 0;
    }
    if (this.detectFilter === DETECT_FILTER_FAILED) {
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

  private refreshDetectProjection(): void {
    const context: SourceRow[] = this.contextRows(this.rows, this.detectAppliedQuery, this.detectGroup);
    let untested: number = 0;
    let failed: number = 0;
    for (const row of context) {
      if (row.detectState.length === 0) {
        untested += 1;
      } else if (row.detectState === 'unavailable') {
        failed += 1;
      }
    }
    this.detectChipTotal = context.length;
    this.detectChipUntested = untested;
    this.detectChipFailed = failed;
    if ((this.detectFilter === DETECT_FILTER_UNTESTED && untested === 0) ||
      (this.detectFilter === DETECT_FILTER_FAILED && failed === 0)) {
      this.detectFilter = DETECT_FILTER_ALL;
    }

    const visible: SourceRow[] = [];
    for (const row of context) {
      if (this.detectFilterMatches(row)) {
        visible.push(row);
      }
    }
    const next: SourceRow[] = sortSourceRowsForManage(visible);
    this.detectDs.setItems(next);
    this.detectListCount = next.length;
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

  private scheduleDetectQuery(value: string): void {
    this.detectQuery = value;
    if (this.detectDebounceId >= 0) {
      clearTimeout(this.detectDebounceId);
    }
    this.detectDebounceId = setTimeout((): void => {
      this.detectDebounceId = -1;
      this.detectAppliedQuery = value;
      this.refreshDetectProjection();
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

  private clearDetectQuery(): void {
    if (this.detectDebounceId >= 0) {
      clearTimeout(this.detectDebounceId);
      this.detectDebounceId = -1;
    }
    this.detectQuery = '';
    this.detectAppliedQuery = '';
    this.refreshDetectProjection();
  }

  private selectSourceFilter(index: number): void {
    this.sourceFilter = index;
    this.refreshSourceProjection();
  }

  private selectDetectFilter(index: number): void {
    this.detectFilter = index;
    this.refreshDetectProjection();
  }

  private selectSourceGroup(group: string | undefined): void {
    this.sourceGroup = group;
    this.refreshSourceProjection();
  }

  private selectDetectGroup(group: string | undefined): void {
    this.detectGroup = group;
    this.refreshDetectProjection();
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

  private clearDetectCriteria(): void {
    if (this.detectDebounceId >= 0) {
      clearTimeout(this.detectDebounceId);
      this.detectDebounceId = -1;
    }
    this.detectQuery = '';
    this.detectAppliedQuery = '';
    this.detectFilter = DETECT_FILTER_ALL;
    this.detectGroup = undefined;
    this.refreshDetectProjection();
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
      this.detectGroups = this.collectGroups(next);
      this.resetStaleGroups();
      this.refreshSourceProjection();
      this.refreshDetectProjection();
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
      this.refreshDetectProjection();
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
    this.detectResults = [];
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

  private openDetectStatus(): void {
    this.sourceDetailRequest += 1;
    this.selectedSource = undefined;
    this.sourceDetail = undefined;
    this.sourceDetailLoading = false;
    this.sourceDetailFailed = false;
    this.statusVisible = true;
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

  private async runDetect(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    let enabled: BookSource[] = [];
    try {
      await ensureSourceStore(ctx);
      enabled = await allForEngine({ enabled: true });
    } catch (err) {
      this.summary = '检测失败';
      return;
    }
    if (enabled.length === 0) {
      this.summary = '没有启用的书源';
      return;
    }
    this.busy = true;
    this.detectResults = [];
    this.statusVisible = false;
    try {
      this.detectResults = await bookEngine.detect(enabled, DEFAULT_DETECT_KEYWORD);
      this.summary = this.detectSummary();
      this.jobText = this.detectSummary();
      this.statusVisible = true;
    } catch (err) {
      this.summary = '检测失败';
    } finally {
      this.busy = false;
    }
  }

  private countState(state: DetectState): number {
    let n = 0;
    for (const r of this.detectResults) {
      if (detectStateOf(r) === state) {
        n += 1;
      }
    }
    return n;
  }

  private sourceRowKey(source: SourceRow): string {
    return source.id.toString() + '#' + (source.enabled ? '1' : '0');
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

  private detectGroupMenuItems(): MenuElement[] {
    return this.groupMenuItems(this.detectGroups,
      (next: string | undefined) => this.selectDetectGroup(next));
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

  private detectSummary(): string {
    return `检测完成：可用 ${this.countState('ok')} / 无结果 ${this.countState('noResult')} / ` +
      `超时 ${this.countState('timeout')} / 不可用 ${this.countState('unavailable')}`;
  }

  /** 检测结果是自然键（URL + 名称）；同 URL 孪生源不能按 URL 批量误伤。 */
  private unavailableKeys(): Set<string> {
    const set: Set<string> = new Set<string>();
    for (const r of this.detectResults) {
      if (detectStateOf(r) === 'unavailable') {
        set.add(sourceNaturalKey(r.sourceUrl, r.sourceName));
      }
    }
    return set;
  }

  private unavailableIds(): Set<number> {
    const keys: Set<string> = this.unavailableKeys();
    const ids: Set<number> = new Set<number>();
    for (const row of this.rows) {
      if (keys.has(sourceNaturalKey(row.url, row.name))) {
        ids.add(row.id);
      }
    }
    return ids;
  }

  /** One-tap: turn off every source judged hard-unavailable. */
  private async disableUnavailable(): Promise<void> {
    const ids: Set<number> = this.unavailableIds();
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
        if (ids.has(row.id) && row.enabled) {
          await setEnabled(row.id, false);
          changed += 1;
        }
      }
      if (changed > 0) {
        await this.reload();
      }
    } catch (err) {
      this.summary = '关闭不可用源失败';
      return;
    }
    this.summary = changed > 0 ? `已关闭 ${changed} 个不可用源` : '不可用源均已关闭';
  }

  /** One-tap: remove every source judged hard-unavailable. */
  private async deleteUnavailable(): Promise<void> {
    const keys: Set<string> = this.unavailableKeys();
    const ids: Set<number> = this.unavailableIds();
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
        if (ids.has(row.id)) {
          await remove(row.id);
          removed += 1;
        }
      }
      await this.reload();
    } catch (err) {
      this.summary = '删除不可用源失败';
      return;
    }
    this.detectResults = this.detectResults.filter((r: DetectResult) =>
      !keys.has(sourceNaturalKey(r.sourceUrl, r.sourceName)));
    this.summary = `已删除 ${removed} 个不可用源`;
    if (this.detectResults.length === 0) {
      this.statusVisible = false;
    }
  }

  private stateColor(state: DetectState): Resource {
    if (state === 'ok') {
      return $r('app.color.brand');
    }
    if (state === 'noResult') {
      return $r('app.color.text_3');
    }
    if (state === 'timeout') {
      return $r('app.color.info');
    }
    return $r('app.color.warning');
  }

  private resultDetail(result: DetectResult): string {
    const state: DetectState = detectStateOf(result);
    if (state === 'ok') {
      return `正文 ${result.contentLen} 字 · ${result.elapsedMs}ms`;
    }
    return `${detectStageLabel(result.stage)} · ${result.elapsedMs}ms`;
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

  @Builder
  statusRow(result: DetectResult) {
    Row() {
      Column({ space: 3 }) {
        Text(result.sourceName.length > 0 ? result.sourceName : result.sourceUrl)
          .fontSize(14)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.resultDetail(result))
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(detectStateLabel(detectStateOf(result)))
        .fontSize(12)
        .fontColor(this.stateColor(detectStateOf(result)))
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .backgroundColor($r('app.color.bg_pill'))
        .borderRadius(10)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  statusContent() {
    Column() {
      Text(this.detectSummary())
        .fontSize(14)
        .fontColor($r('app.color.text_1'))
        .width('100%')
      Text('可用=完整链路通过；无结果=探测词未命中，源未必失效；超时=请求超时，可能瞬时。' +
        '以上两者不参与一键清理。不可用=链路失败（网络/解析/规则缺失等），可一键关闭或删除。')
        .fontSize(12)
        .fontColor($r('app.color.text_4'))
        .width('100%')
        .margin({ top: 6 })

      Scroll() {
        Column() {
          ForEach(this.detectResults, (result: DetectResult, index: number) => {
            this.statusRow(result)
            if (index < this.detectResults.length - 1) {
              InsetDivider()
            }
          }, (result: DetectResult, index: number) => result.sourceUrl + '|' + index.toString())
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 320 })
      .scrollBar(BarState.Off)
      .margin({ top: 8 })

      Row({ space: 12 }) {
        Button(`关闭全部不可用（${this.countState('unavailable')}）`)
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .fontColor($r('app.color.brand'))
          .backgroundColor($r('app.color.bg_pill'))
          .borderRadius(22)
          .enabled(this.countState('unavailable') > 0)
          .onClick(() => {
            this.disableUnavailable();
          })
        Button(`删除全部不可用（${this.countState('unavailable')}）`)
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(22)
          .enabled(this.countState('unavailable') > 0)
          .onClick(() => {
            this.deleteUnavailable();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
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
  detectSearchBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([$r('app.color.text_4')])
      TextInput({ text: this.detectQuery, placeholder: '搜索检测结果' })
        .layoutWeight(1)
        .height(44)
        .fontSize(15)
        .fontColor($r('app.color.text_1'))
        .placeholderColor($r('app.color.text_5'))
        .backgroundColor(Color.Transparent)
        .padding({ left: 8, right: 0 })
        .onChange((value: string) => {
          this.scheduleDetectQuery(value);
        })
      if (this.detectQuery.length > 0) {
        Text('✕')
          .fontSize(14)
          .fontColor($r('app.color.text_4'))
          .padding({ left: 6, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.clearDetectQuery();
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
  emptyState(sourceScope: boolean) {
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
          } else if (sourceScope) {
            this.clearSourceCriteria();
          } else {
            this.clearDetectCriteria();
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
          this.emptyState(true)
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
    Column() {
      Column({ space: 8 }) {
        this.detectSearchBar()
        Scroll() {
          Row({ space: 8 }) {
            ManageFilterChip({
              label: '全部 ' + this.detectChipTotal.toString(),
              selected: this.detectFilter === DETECT_FILTER_ALL,
              onSelect: () => this.selectDetectFilter(DETECT_FILTER_ALL)
            })
            if (this.detectChipUntested > 0) {
              ManageFilterChip({
                label: '未测 ' + this.detectChipUntested.toString(),
                selected: this.detectFilter === DETECT_FILTER_UNTESTED,
                onSelect: () => this.selectDetectFilter(DETECT_FILTER_UNTESTED)
              })
            }
            if (this.detectChipFailed > 0) {
              ManageFilterChip({
                label: '失败 ' + this.detectChipFailed.toString(),
                selected: this.detectFilter === DETECT_FILTER_FAILED,
                onSelect: () => this.selectDetectFilter(DETECT_FILTER_FAILED)
              })
            }
            Text(this.groupLabel(this.detectGroup))
              .fontSize(13)
              .fontColor(this.detectGroup === undefined ? $r('app.color.text_2') : $r('app.color.brand'))
              .backgroundColor($r('app.color.bg_pill'))
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(16)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .bindMenu(this.detectGroupMenuItems())
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

      Row({ space: 12 }) {
        if (this.detectResults.length > 0) {
          Text('查看状态')
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              this.openDetectStatus();
            })
        }
        Blank()
        Button(this.busy ? '处理中…' : '检测可用性')
          .height(36)
          .fontSize(14)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(18)
          .enabled(!this.busy)
          .onClick(() => {
            this.runDetect();
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Stack() {
        List({ scroller: this.detectScroller }) {
          LazyForEach(this.detectDs, (source: SourceRow) => {
            ListItem() {
              SourceManageRow({
                source: source,
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
          }, (source: SourceRow) => 'detect_' + this.sourceRowKey(source))
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
        .visibility(this.detectListCount === 0 ? Visibility.Hidden : Visibility.Visible)

        if (this.detectListCount === 0) {
          this.emptyState(false)
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .visibility(this.activeSegment === 1 ? Visibility.Visible : Visibility.Hidden)
  }

  @Builder
  jobBar() {
    Row({ space: 10 }) {
      Row()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(this.busy ? $r('app.color.info') : $r('app.color.brand'))
      Text(this.jobText)
        .fontSize(13)
        .fontColor($r('app.color.text_2'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([$r('app.color.text_4')])
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
    .margin({ left: 16, right: 16, top: 6, bottom: 8 })
    .accessibilityText('查看检测作业')
    .accessibilityLevel('yes')
    .onClick(() => {
      this.activeSegment = 1;
    })
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
        title: this.selectedSource !== undefined ? '书源详情' : '书源状态',
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
        } else {
          this.statusContent()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}

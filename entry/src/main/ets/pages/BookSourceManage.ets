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
  removeMany,
  replaceAll,
  setEnabled,
  setEnabledMany,
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
import { DetectProgressCard } from '../components/DetectProgressCard';
import { SourceManageRow, sortSourceRowsForManage } from '../components/SourceRows';
import {
  SourceDetailData,
  SourceDetailPanel
} from '../components/SourceDetailPanel';
import { BottomDrawer } from '../ui/common/BottomDrawer';
import { MoreMenuButton } from '../ui/common/MoreMenuButton';
import {
  DEFAULT_DETECT_KEYWORD,
  DETECT_INCREMENTAL_WINDOW_MS,
  ENGINE_FETCH_TIMEOUT_MS
} from '../common/Const';
import {
  DETECT_BACKGROUND_INACTIVE,
  DetectJobRunner
} from '../model/DetectJobRunner';
import {
  DETECT_MODE_FULL,
  DETECT_MODE_PROBE,
  DETECT_STATUS_RUNNING
} from '../model/DetectJob';

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

/**
 * 书源管理页：页面主体只有书源列表。
 *
 * 所有页面级动作（导入 / 导出 / 检测 / 恢复内置 / 调试器）收进标题下的单一 `⋯` 功能键；
 * 检测进行中时整页切成任务态，只保留进度卡与取消。
 * 约定见 docs/specs/SPEC-BOOKSOURCE-LAYOUT.md §3。
 */
@ComponentV2
export struct BookSourceManagePage {
  @Local rows: SourceRow[] = [];
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
  @Local detectView: boolean = false;
  @Local detectMode: string = DETECT_MODE_FULL;
  @Local detectClockNow: number = Date.now();
  @Local detectLaunching: boolean = false;
  @Local detectCanResume: boolean = false;
  @Local detectBackgroundState: string = DETECT_BACKGROUND_INACTIVE;
  @Local detectIncrementCount: number = 0;
  @Local detectEnabledCount: number = 0;
  @Local unavailableCount: number = 0;
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
  private sourceDetailRequest: number = 0;
  private detectClockId: number = -1;

  @Monitor('runner.updatedAt', 'runner.status')
  onDetectJobChanged(): void {
    this.syncDetectJobView();
    if (this.runner.status === DETECT_STATUS_RUNNING) {
      this.detectView = true;
    }
    this.reload();
  }

  aboutToAppear(): void {
    this.pageStartedAt = Date.now();
    this.detectClockNow = this.pageStartedAt;
    this.startDetectClock();
    this.preparePage();
  }

  aboutToDisappear(): void {
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
      this.refreshProjection();
      this.refreshDetectCounts();
    } catch (err) {
      this.rows = [];
      this.totalRows = 0;
      this.enabledRows = 0;
      this.refreshProjection();
      this.refreshDetectCounts();
    }
  }

  /** Menu labels and the cleanup entry share one pass over the projection. */
  private refreshDetectCounts(): void {
    const now: number = Date.now();
    let enabled: number = 0;
    let increment: number = 0;
    let unavailable: number = 0;
    for (const row of this.rows) {
      if (row.detectState === 'unavailable') {
        unavailable += 1;
      }
      if (!row.enabled) {
        continue;
      }
      enabled += 1;
      if (this.inIncrementalScope(row, now)) {
        increment += 1;
      }
    }
    this.detectEnabledCount = enabled;
    this.detectIncrementCount = increment;
    this.unavailableCount = unavailable;
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

  private inIncrementalScope(row: SourceRow, now: number): boolean {
    if (!row.enabled) {
      return false;
    }
    if (row.detectState.length === 0 || row.detectState === 'unavailable') {
      return true;
    }
    return row.detectAt <= 0 || now - row.detectAt >= DETECT_INCREMENTAL_WINDOW_MS;
  }

  /** One flat list: the detection states that need work sort to the front. */
  private refreshProjection(): void {
    const next: SourceRow[] = sortSourceRowsForManage(this.rows);
    this.sourceDs.setItems(next);
    this.sourceListCount = next.length;
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

  private incrementalIds(): string[] {
    const now: number = Date.now();
    const ids: string[] = [];
    for (const row of this.rows) {
      if (this.inIncrementalScope(row, now)) {
        ids.push(row.id.toString());
      }
    }
    return ids;
  }

  private unavailableIds(): number[] {
    const ids: number[] = [];
    for (const row of this.rows) {
      if (row.detectState === 'unavailable') {
        ids.push(row.id);
      }
    }
    return ids;
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
      // 冷启动回到本页时，只有真在跑的作业才进入任务态；已完成/已取消的轮次不占屏。
      this.detectView = this.runner.status === DETECT_STATUS_RUNNING;
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
      const text: string = await bookEngine.fetchText(url, ENGINE_FETCH_TIMEOUT_MS);
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
    const monthValue: number = date.getMonth() + 1;
    const month: string = monthValue < 10 ? '0' + monthValue.toString() : monthValue.toString();
    const dayValue: number = date.getDate();
    const day: string = dayValue < 10 ? '0' + dayValue.toString() : dayValue.toString();
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
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = ['book-sources_' + this.dateStr() + '.json'];
      options.fileSuffixChoices = ['JSON|.json'];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
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
      this.refreshProjection();
      this.refreshDetectCounts();
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
      this.refreshProjection();
      this.refreshDetectCounts();
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
      message: '将删除当前 ' + this.totalRows.toString() + ' 条书源，并用内置书源替换。此操作不可撤销。',
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

  /** 菜单入口：先切任务态，启动被拒绝时再退回列表。 */
  private async startDetect(mode: string, sourceIds: string[]): Promise<void> {
    if (sourceIds.length === 0) {
      this.summary = '当前范围没有可检测的书源';
      return;
    }
    this.detectView = true;
    const accepted: boolean = await this.launchDetect(mode, sourceIds);
    if (!accepted) {
      this.detectView = false;
    }
  }

  private async launchDetect(mode: string, sourceIds: string[]): Promise<boolean> {
    if (this.detectLaunching) {
      return false;
    }
    if (sourceIds.length === 0) {
      this.summary = '当前范围没有可检测的书源';
      return false;
    }
    this.detectLaunching = true;
    let accepted: boolean = false;
    try {
      accepted = await this.runner.start(mode, DEFAULT_DETECT_KEYWORD, sourceIds);
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
    return accepted;
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

  /** 单一功能键：页面级 / 批量 / 破坏性动作都在这里，列表上方不再有常驻工具栏。 */
  private moreMenuItems(): MenuElement[] {
    const items: MenuElement[] = [
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
        value: '导出书源',
        action: () => {
          this.exportSources();
        }
      },
      {
        value: '检测书源（增量 ' + this.detectIncrementCount.toString() + '）',
        enabled: this.detectIncrementCount > 0,
        action: () => {
          this.startDetect(DETECT_MODE_PROBE, this.incrementalIds());
        }
      },
      {
        value: '全部重测（' + this.detectEnabledCount.toString() + '）',
        enabled: this.detectEnabledCount > 0,
        action: () => {
          this.startDetect(DETECT_MODE_FULL, this.enabledIds());
        }
      },
      {
        value: '规则调试器',
        action: () => this.onOpenDebugger()
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
      const idsToDisable: number[] = [];
      for (const row of this.rows) {
        if (ids.has(row.id) && row.detectState === 'unavailable' && row.enabled) {
          idsToDisable.push(row.id);
        }
      }
      changed = idsToDisable.length;
      await setEnabledMany(idsToDisable, false);
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
      const idsToRemove: number[] = [];
      for (const row of this.rows) {
        if (ids.has(row.id) && row.detectState === 'unavailable') {
          idsToRemove.push(row.id);
        }
      }
      removed = idsToRemove.length;
      await removeMany(idsToRemove);
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

  private headerSummary(): string {
    if (this.totalRows === 0) {
      return '还没有书源';
    }
    return this.totalRows.toString() + ' 个书源 · ' + this.enabledRows.toString() + ' 启用';
  }

  @Builder
  pageHeader() {
    Row() {
      Text(this.headerSummary())
        .fontSize(13)
        .fontColor($r('app.color.text_3'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      MoreMenuButton({
        items: this.moreMenuItems(),
        label: '书源操作'
      })
    }
    .width('100%')
    .height(48)
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
  emptyState() {
    Column({ space: 10 }) {
      Text('还没有书源')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))
      Text('导入书源文件，或恢复内置书源。')
        .fontSize(13)
        .fontColor($r('app.color.text_4'))
      Row({ space: 10 }) {
        Button('导入书源')
          .height(36)
          .fontSize(14)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(18)
          .margin({ top: 4 })
          .onClick(() => {
            this.importFromFile();
          })
        Button('恢复内置')
          .height(36)
          .fontSize(14)
          .fontColor($r('app.color.text_2'))
          .backgroundColor($r('app.color.bg_pill'))
          .borderRadius(18)
          .margin({ top: 4 })
          .onClick(() => {
            this.confirmResetBundled();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  sourceList() {
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
    .visibility(this.detectView ? Visibility.Hidden : Visibility.Visible)
  }

  @Builder
  detectBody() {
    Column() {
      DetectProgressCard({
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
        unavailableCount: this.unavailableCount,
        onCancel: () => {
          this.cancelDetect();
        },
        onResume: () => {
          this.resumeDetect();
        },
        onBack: () => {
          this.detectView = false;
        },
        onDisableUnavailable: () => {
          this.confirmDisableUnavailable(this.unavailableIds());
        },
        onDeleteUnavailable: () => {
          this.confirmDeleteUnavailable(this.unavailableIds());
        }
      })
    }
    .layoutWeight(1)
    .width('100%')
    .visibility(this.detectView ? Visibility.Visible : Visibility.Hidden)
  }

  build() {
    Stack() {
      Column() {
        if (!this.detectView) {
          this.pageHeader()
        }
        if (this.showUrl) {
          this.urlImportBar()
        }
        if (this.summary.length > 0) {
          this.summaryBanner()
        }
        Stack() {
          this.sourceList()
          this.detectBody()
        }
        .layoutWeight(1)
        .width('100%')
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
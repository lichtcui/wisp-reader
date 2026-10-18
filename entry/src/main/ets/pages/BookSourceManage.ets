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
  @Local sourceFilter: number = 0;
  @Local detectQuery: string = '';
  @Local detectFilter: number = 0;
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
  @Event onOpenDebugger: () => void = () => {};
  private pageStartedAt: number = 0;
  private t16Pending: boolean = false;
  private t16MeasureStarted: boolean = false;
  private sourceDs: SourceManageDataSource = new SourceManageDataSource();
  private detectDs: SourceManageDataSource = new SourceManageDataSource();
  private sourceScroller: Scroller = new Scroller();
  private detectScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.activeSegment = 0;
    this.pageStartedAt = Date.now();
    this.preparePage();
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
      // Both segments view the same projection array; only their scroll and
      // filter state are independent.
      this.sourceDs.setItems(next);
      this.detectDs.setItems(next);
      this.totalRows = next.length;
      this.enabledRows = this.countEnabled(next);
    } catch (err) {
      this.rows = [];
      this.sourceDs.setItems(this.rows);
      this.detectDs.setItems(this.rows);
      this.totalRows = 0;
      this.enabledRows = 0;
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
      this.sourceDs.setItems(next);
      this.detectDs.setItems(next);
      this.totalRows = next.length;
      this.enabledRows = this.countEnabled(next);
    } catch (err) {
      this.summary = '删除失败';
    }
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
      this.sourceDs.setItems(this.rows);
      this.detectDs.setItems(this.rows);
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
          this.resetBundled();
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
          this.sourceQuery = value;
        })
      if (this.sourceQuery.length > 0) {
        Text('✕')
          .fontSize(14)
          .fontColor($r('app.color.text_4'))
          .padding({ left: 6, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.sourceQuery = '';
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
          this.detectQuery = value;
        })
      if (this.detectQuery.length > 0) {
        Text('✕')
          .fontSize(14)
          .fontColor($r('app.color.text_4'))
          .padding({ left: 6, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.detectQuery = '';
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
  sourceRowCell(source: SourceRow) {
    Row() {
      Column({ space: 3 }) {
        Text(source.name.length > 0 ? source.name : source.url)
          .fontSize(16)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(source.url)
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(source.group.length > 0 ? source.group : '默认')
          .fontSize(11)
          .fontColor($r('app.color.text_3'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: source.enabled })
        .selectedColor($r('app.color.brand'))
        .onChange((on: boolean) => {
          this.toggleSource(source, on);
        })
      Text('删除')
        .fontSize(13)
        .fontColor($r('app.color.brand'))
        .margin({ left: 12 })
        .onClick(() => {
          this.removeSource(source);
        })
    }
    .width('100%')
    .height(84)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sourceSegment() {
    Column() {
      Column({ space: 8 }) {
        this.sourceSearchBar()
        Row({ space: 8 }) {
          ManageFilterChip({
            label: '全部',
            selected: this.sourceFilter === 0,
            onSelect: () => {
              this.sourceFilter = 0;
            }
          })
          ManageFilterChip({
            label: '启用',
            selected: this.sourceFilter === 1,
            onSelect: () => {
              this.sourceFilter = 1;
            }
          })
          ManageFilterChip({
            label: '停用',
            selected: this.sourceFilter === 2,
            onSelect: () => {
              this.sourceFilter = 2;
            }
          })
          ManageFilterChip({
            label: '未测',
            selected: this.sourceFilter === 3,
            onSelect: () => {
              this.sourceFilter = 3;
            }
          })
          ManageFilterChip({
            label: '失败',
            selected: this.sourceFilter === 4,
            onSelect: () => {
              this.sourceFilter = 4;
            }
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      Row() {
        Text(`书源 ${this.enabledRows}/${this.totalRows} 启用`)
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
      }
      .width('100%')
      .height(32)
      .padding({ left: 16, right: 16 })

      List({ scroller: this.sourceScroller }) {
        LazyForEach(this.sourceDs, (source: SourceRow) => {
          ListItem() {
            this.sourceRowCell(source)
          }
        }, (source: SourceRow) => this.sourceRowKey(source))
      }
      .layoutWeight(1)
      .width('100%')
      .divider({
        strokeWidth: 1,
        color: $r('app.color.divider'),
        startMargin: 16
      })
      .cachedCount(8)
      .scrollBar(BarState.Off)
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
        Row({ space: 8 }) {
          ManageFilterChip({
            label: '全部',
            selected: this.detectFilter === 0,
            onSelect: () => {
              this.detectFilter = 0;
            }
          })
          ManageFilterChip({
            label: '未测',
            selected: this.detectFilter === 1,
            onSelect: () => {
              this.detectFilter = 1;
            }
          })
          ManageFilterChip({
            label: '失败',
            selected: this.detectFilter === 2,
            onSelect: () => {
              this.detectFilter = 2;
            }
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      Row({ space: 12 }) {
        if (this.detectResults.length > 0) {
          Text('查看状态')
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              this.statusVisible = true;
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

      List({ scroller: this.detectScroller }) {
        LazyForEach(this.detectDs, (source: SourceRow) => {
          ListItem() {
            this.sourceRowCell(source)
          }
        }, (source: SourceRow) => 'detect_' + this.sourceRowKey(source))
      }
      .layoutWeight(1)
      .width('100%')
      .divider({
        strokeWidth: 1,
        color: $r('app.color.divider'),
        startMargin: 16
      })
      .cachedCount(8)
      .scrollBar(BarState.Off)
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
        title: '书源状态',
        sheetSize: 'large',
        mode: 'overlay',
        onClose: () => {
          this.statusVisible = false;
        }
      }) {
        this.statusContent()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}

import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import BuildProfile from 'BuildProfile';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource, DetectResult, ExcludedSource, GateResult } from '../engine/types';
import { loadBundled } from '../model/SourceRepository';
import {
  allForEngine,
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
import { GroupTitle, InsetDivider, NavCell } from '../components/ListCells';
import { BottomDrawer } from '../ui/common/BottomDrawer';
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

@ComponentV2
export struct BookSourceManagePage {
  @Local sources: SourceRow[] = [];
  @Local summary: string = '';
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

  aboutToAppear(): void {
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
      this.sources = await listRows();
    } catch (err) {
      this.sources = [];
    }
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

  private async removeSource(row: SourceRow): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    try {
      await ensureSourceStore(ctx);
      await remove(row.id);
      this.sources = this.sources.filter((source: SourceRow) => source.id !== row.id);
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
      const next: SourceRow[] = this.sources.slice();
      for (const source of next) {
        if (source.id === row.id) {
          source.enabled = on;
          break;
        }
      }
      this.sources = next;
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

  private enabledCount(): number {
    let n: number = 0;
    for (const row of this.sources) {
      if (row.enabled) {
        n += 1;
      }
    }
    return n;
  }

  private sourceRowKey(source: SourceRow): string {
    return source.id.toString() + '#' + (source.enabled ? '1' : '0');
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
    for (const row of this.sources) {
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
      for (const row of this.sources) {
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
      for (const row of this.sources) {
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
  actionChip(label: string, onTap: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor($r('app.color.brand'))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(16)
      .backgroundColor($r('app.color.bg_pill'))
      .onClick(onTap)
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

  build() {
    Stack() {
      Column() {
        Scroll() {
          Column() {
            GroupTitle({ text: '导入' })
            Row({ space: 10 }) {
              this.actionChip('从文件', () => {
                this.importFromFile();
              })
              this.actionChip('从链接', () => {
                this.showUrl = !this.showUrl;
              })
              this.actionChip('恢复内置', () => {
                this.resetBundled();
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16 })

            if (this.showUrl) {
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
              .padding({ left: 16, right: 16, top: 10 })
            }

            if (this.summary.length > 0) {
              Column({ space: 6 }) {
                Text(this.summary)
                  .fontSize(14)
                  .fontColor($r('app.color.text_1'))
                  .width('100%')
                if (this.excluded.length > 0) {
                  Text(this.reasonCounts())
                    .fontSize(13)
                    .fontColor($r('app.color.text_4'))
                    .width('100%')
                  Text(this.showExcluded ? '收起明细' : '查看排除明细')
                    .fontSize(13)
                    .fontColor($r('app.color.brand'))
                    .onClick(() => {
                      this.showExcluded = !this.showExcluded;
                    })
                  if (this.showExcluded) {
                    ForEach(this.excluded, (e: ExcludedSource) => {
                      Row() {
                        Text(e.bookSourceName.length > 0 ? e.bookSourceName : e.bookSourceUrl)
                          .fontSize(13)
                          .fontColor($r('app.color.text_2'))
                          .layoutWeight(1)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(reasonLabel(e.reason))
                          .fontSize(12)
                          .fontColor($r('app.color.warning'))
                      }
                      .width('100%')
                      .padding({ top: 4, bottom: 4 })
                    }, (e: ExcludedSource) => e.bookSourceUrl + '_' + e.reason)
                  }
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(12)
              .margin({ left: 16, right: 16, top: 12 })
            }

            GroupTitle({ text: '工具' })
            NavCell({
              label: '规则调试器',
              value: '',
              showArrow: true,
              onTap: () => this.onOpenDebugger()
            })
            if (BuildProfile.DEBUG) {
              NavCell({
                label: 'T1.6 性能造数（3000）',
                value: '',
                showArrow: true,
                onTap: () => this.confirmT16Seed()
              })
            }

            GroupTitle({ text: `书源（${this.enabledCount()}/${this.sources.length} 启用）` })
            Column() {
              ForEach(this.sources, (source: SourceRow, index: number) => {
                Column() {
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
                      if (source.group.length > 0) {
                        Text(source.group)
                          .fontSize(11)
                          .fontColor($r('app.color.text_3'))
                      }
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
                  .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                  .alignItems(VerticalAlign.Center)
                  if (index < this.sources.length - 1) {
                    InsetDivider()
                  }
                }
              }, (source: SourceRow, index: number) =>
              // key 必须同时满足两点：① 唯一——同一 URL 可以有多条，`id` 是存储主键；
              // ② 含 `enabled`——否则启停后 key 不变，ForEach 不重建该行，开关显示旧值。
              this.sourceRowKey(source))
            }
            .width('100%')

            if (this.detectResults.length > 0) {
              Row() {
                Text(this.detectSummary())
                  .fontSize(12)
                  .fontColor($r('app.color.text_4'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('书源状态')
                  .fontSize(12)
                  .fontColor($r('app.color.brand'))
                  .onClick(() => {
                    this.statusVisible = true;
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12 })
            }

            Row({ space: 12 }) {
              Button(this.busy ? '处理中…' : '检测可用性')
                .layoutWeight(1)
                .height(48)
                .fontSize(16)
                .fontColor($r('app.color.on_brand'))
                .backgroundColor($r('app.color.brand'))
                .borderRadius(24)
                .enabled(!this.busy)
                .onClick(() => {
                  this.runDetect();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 20, bottom: 40 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
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

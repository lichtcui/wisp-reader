import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource, DetectResult, ExcludedSource, GateResult } from '../engine/types';
import { enabledSources, loadSources, resetToBundled, saveSources } from '../model/SourceRepository';
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
  @Local sources: BookSource[] = [];
  @Local summary: string = '';
  @Local excluded: ExcludedSource[] = [];
  @Local showExcluded: boolean = false;
  @Local showUrl: boolean = false;
  @Local urlInput: string = '';
  @Local busy: boolean = false;
  @Local detectResults: DetectResult[] = [];
  @Local statusVisible: boolean = false;
  @Event onOpenDebugger: () => void = () => {};

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx !== undefined) {
      this.sources = loadSources(ctx);
    }
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private persist(): void {
    const ctx = this.ctx();
    if (ctx !== undefined) {
      saveSources(ctx, this.sources);
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

  private applyGate(list: BookSource[]): void {
    if (list.length === 0) {
      this.summary = '未解析到有效书源';
      this.excluded = [];
      return;
    }
    const result: GateResult = bookEngine.gate(list);
    const existing: BookSource[] = this.sources.slice();
    const map: Map<string, BookSource> = new Map<string, BookSource>();
    for (const s of existing) {
      map.set(s.bookSourceUrl, s);
    }
    for (const s of result.eligible) {
      map.set(s.bookSourceUrl, s);
    }
    const merged: BookSource[] = [];
    map.forEach((value: BookSource) => merged.push(value));
    this.sources = merged;
    this.persist();
    this.excluded = result.excluded;
    this.showExcluded = false;
    // "规则通过" not "成功": the import gate only checks rule shape, it does
    // not prove the source works at runtime (use 检测可用性 for that).
    this.summary = `规则通过 ${result.eligible.length} / 规则排除 ${result.excluded.length}`;
  }

  private importText(text: string): void {
    this.applyGate(this.normalize(text));
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
      this.importText(text);
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
      this.importText(text);
      this.showUrl = false;
      this.urlInput = '';
    } catch (err) {
      this.summary = 'URL 下载失败';
    } finally {
      this.busy = false;
    }
  }

  private removeSource(index: number): void {
    const next: BookSource[] = this.sources.slice();
    next.splice(index, 1);
    this.sources = next;
    this.persist();
  }

  private toggleSource(index: number, on: boolean): void {
    const next: BookSource[] = this.sources.slice();
    const item: BookSource = next[index];
    item.enabled = on;
    this.sources = next;
    this.persist();
  }

  private resetBundled(): void {
    const ctx = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.sources = resetToBundled(ctx);
    this.summary = `已恢复内置书源 ${this.sources.length} 个`;
    this.excluded = [];
    this.detectResults = [];
    this.statusVisible = false;
  }

  private async runDetect(): Promise<void> {
    if (this.busy) {
      return;
    }
    const enabled: BookSource[] = enabledSources(this.sources);
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

  private detectSummary(): string {
    return `检测完成：可用 ${this.countState('ok')} / 无结果 ${this.countState('noResult')} / ` +
      `超时 ${this.countState('timeout')} / 不可用 ${this.countState('unavailable')}`;
  }

  private unavailableUrls(): Set<string> {
    const set: Set<string> = new Set<string>();
    for (const r of this.detectResults) {
      if (detectStateOf(r) === 'unavailable') {
        set.add(r.sourceUrl);
      }
    }
    return set;
  }

  /** One-tap: turn off every source judged hard-unavailable. */
  private disableUnavailable(): void {
    const bad: Set<string> = this.unavailableUrls();
    if (bad.size === 0) {
      return;
    }
    let changed: number = 0;
    const next: BookSource[] = [];
    for (const s of this.sources) {
      if (bad.has(s.bookSourceUrl) && s.enabled !== false) {
        s.enabled = false;
        changed += 1;
      }
      next.push(s);
    }
    this.sources = next;
    this.persist();
    this.summary = changed > 0 ? `已关闭 ${changed} 个不可用源` : '不可用源均已关闭';
  }

  /** One-tap: remove every source judged hard-unavailable. */
  private deleteUnavailable(): void {
    const bad: Set<string> = this.unavailableUrls();
    if (bad.size === 0) {
      return;
    }
    const next: BookSource[] = this.sources.filter((s: BookSource) => !bad.has(s.bookSourceUrl));
    const removed: number = this.sources.length - next.length;
    this.sources = next;
    this.persist();
    this.detectResults = this.detectResults.filter((r: DetectResult) => !bad.has(r.sourceUrl));
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

            GroupTitle({ text: `书源（${enabledSources(this.sources).length}/${this.sources.length} 启用）` })
            Column() {
              ForEach(this.sources, (source: BookSource, index: number) => {
                Column() {
                  Row() {
                    Column({ space: 3 }) {
                      Text(source.bookSourceName.length > 0 ? source.bookSourceName : source.bookSourceUrl)
                        .fontSize(16)
                        .fontColor($r('app.color.text_1'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(source.bookSourceUrl)
                        .fontSize(12)
                        .fontColor($r('app.color.text_4'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (source.bookSourceGroup !== undefined && source.bookSourceGroup.length > 0) {
                        Text(source.bookSourceGroup)
                          .fontSize(11)
                          .fontColor($r('app.color.text_3'))
                      }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Toggle({ type: ToggleType.Switch, isOn: source.enabled !== false })
                      .selectedColor($r('app.color.brand'))
                      .onChange((on: boolean) => {
                        this.toggleSource(index, on);
                      })
                    Text('删除')
                      .fontSize(13)
                      .fontColor($r('app.color.brand'))
                      .margin({ left: 12 })
                      .onClick(() => {
                        this.removeSource(index);
                      })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                  .alignItems(VerticalAlign.Center)
                  if (index < this.sources.length - 1) {
                    InsetDivider()
                  }
                }
              }, (source: BookSource) => source.bookSourceUrl + '#' + (source.enabled !== false ? '1' : '0'))
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

      if (this.statusVisible) {
        BottomDrawer({
          visible: true,
          title: '书源状态',
          sheetSize: 'large',
          mode: 'system',
          onClose: () => {
            this.statusVisible = false;
          }
        }) {
          this.statusContent()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
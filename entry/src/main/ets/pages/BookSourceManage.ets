import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource, DetectResult, ExcludedSource, GateResult } from '../engine/types';
import { enabledSources, loadSources, resetToBundled, saveSources } from '../model/SourceRepository';
import { GroupTitle, InsetDivider } from '../components/ListCells';
import { DEFAULT_DETECT_KEYWORD } from '../common/Const';

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
    this.summary = `成功 ${result.eligible.length} / 排除 ${result.excluded.length}`;
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

  private importFromClipboard(): void {
    try {
      const data: pasteboard.PasteData = pasteboard.getSystemPasteboard().getDataSync();
      this.importText(data.getPrimaryText());
    } catch (err) {
      this.summary = '剪贴板为空或不可读';
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
  }

  private async runDetect(): Promise<void> {
    const enabled: BookSource[] = enabledSources(this.sources);
    if (enabled.length === 0) {
      this.summary = '没有启用的书源';
      return;
    }
    this.busy = true;
    this.detectResults = [];
    try {
      this.detectResults = await bookEngine.detect(enabled, DEFAULT_DETECT_KEYWORD);
      let ok: number = 0;
      for (const r of this.detectResults) {
        if (r.ok) {
          ok += 1;
        }
      }
      this.summary = `检测完成：可用 ${ok} / ${this.detectResults.length}`;
    } catch (err) {
      this.summary = '检测失败';
    } finally {
      this.busy = false;
    }
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

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '导入' })
          Row({ space: 10 }) {
            this.actionChip('从文件', () => {
              this.importFromFile();
            })
            this.actionChip('剪贴板', () => {
              this.importFromClipboard();
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
            }, (source: BookSource, index: number) => source.bookSourceUrl + '_' + index.toString())
          }
          .width('100%')

          if (this.detectResults.length > 0) {
            GroupTitle({ text: '检测结果' })
            Column() {
              ForEach(this.detectResults, (result: DetectResult) => {
                Row() {
                  Column({ space: 3 }) {
                    Text(result.sourceName.length > 0 ? result.sourceName : result.sourceUrl)
                      .fontSize(14)
                      .fontColor($r('app.color.text_1'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(result.ok ? `可用（${result.contentLen} 字 / ${result.elapsedMs}ms）` : `${result.stage}: ${result.detail}`)
                      .fontSize(12)
                      .fontColor(result.ok ? $r('app.color.text_4') : $r('app.color.warning'))
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Text(result.ok ? '✓' : '✕')
                    .fontSize(18)
                    .fontColor(result.ok ? $r('app.color.brand') : $r('app.color.warning'))
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              }, (result: DetectResult) => result.sourceUrl)
            }
            .width('100%')
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
    .backgroundColor($r('app.color.bg_page'))
  }
}
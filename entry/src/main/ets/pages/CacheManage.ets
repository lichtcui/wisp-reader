import { common } from '@kit.AbilityKit';
import { GroupTitle, InsetDivider } from '../components/ListCells';
import { formatBytes } from '../common/Format';
import { CacheStats, clearCache, getCacheStats } from '../model/CacheRepository';

@ComponentV2
struct CacheStatRow {
  @Param title: string = '';
  @Param bytes: number = 0;
  @Param count: number = 0;

  build() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(16)
          .fontColor($r('app.color.text_1'))
        Text(this.count.toString() + ' 个文件')
          .fontSize(12)
          .fontColor($r('app.color.text_4'))
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Text(formatBytes(this.bytes))
        .fontSize(14)
        .fontColor($r('app.color.text_3'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }
}

@ComponentV2
export struct CacheManagePage {
  @Local imageBytes: number = 0;
  @Local imageCount: number = 0;
  @Local chapterBytes: number = 0;
  @Local chapterCount: number = 0;
  @Local ttsBytes: number = 0;
  @Local ttsCount: number = 0;
  @Local totalBytes: number = 0;
  @Local totalCount: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private reload(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    const stats: CacheStats = getCacheStats(ctx);
    this.imageBytes = stats.image.bytes;
    this.imageCount = stats.image.count;
    this.chapterBytes = stats.chapter.bytes;
    this.chapterCount = stats.chapter.count;
    this.ttsBytes = stats.tts.bytes;
    this.ttsCount = stats.tts.count;
    this.totalBytes = stats.totalBytes;
    this.totalCount = stats.totalCount;
  }

  private onClear(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    clearCache(ctx);
    this.zero();
    this.getUIContext().getPromptAction().showToast({ message: '缓存已清理' });
  }

  private zero(): void {
    this.imageBytes = 0;
    this.imageCount = 0;
    this.chapterBytes = 0;
    this.chapterCount = 0;
    this.ttsBytes = 0;
    this.ttsCount = 0;
    this.totalBytes = 0;
    this.totalCount = 0;
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '缓存占用' })
          CacheStatRow({ title: '图片缓存', bytes: this.imageBytes, count: this.imageCount })
          InsetDivider()
          CacheStatRow({ title: '章节内容缓存', bytes: this.chapterBytes, count: this.chapterCount })
          InsetDivider()
          CacheStatRow({ title: 'TTS 音频缓存', bytes: this.ttsBytes, count: this.ttsCount })
          InsetDivider()
          CacheStatRow({ title: '合计', bytes: this.totalBytes, count: this.totalCount })

          Text('封面与章节在再次打开时会按需重新下载；TTS 音频当前仅内存缓存，不计入占用。')
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
            .lineHeight(18)
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })

          Row() {
            Button('清理全部缓存')
              .width('100%')
              .height(44)
              .fontSize(16)
              .fontColor($r('app.color.on_brand'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(22)
              .enabled(this.totalCount > 0)
              .onClick(() => this.onClear())
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 24 })
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
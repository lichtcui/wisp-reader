import { common } from '@kit.AbilityKit';
import { BookCover } from '../components/BookCover';
import { ListenParam, TTS_SPEED_OPTIONS, TTS_TIMER_OPTIONS, TTS_VOICE_OPTIONS } from '../common/Const';
import { Chapter } from '../engine/types';
import { TtsController } from '../model/TtsController';
import { BottomDrawer } from '../ui/common/BottomDrawer';

function voiceName(person: number): string {
  if (person === 21) {
    return '凌飞哲（男声）';
  }
  return '聆小珊（女声）';
}

function formatTime(ms: number): string {
  const total: number = Math.max(Math.floor(ms / 1000), 0);
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? '0' + m.toString() : m.toString();
  const ss: string = s < 10 ? '0' + s.toString() : s.toString();
  return mm + ':' + ss;
}

/**
 * M5 full-screen listening page (plan Appendix 7): cover, chapter + book info,
 * paragraph progress, transport controls (speed / prev / play / next / timer)
 * and voice picker. Playback itself lives in `TtsController`, so minimizing the
 * page keeps the session (and the shelf FAB) alive.
 */
@ComponentV2
export struct ListeningPage {
  @Param param: ListenParam | undefined = undefined;
  @Event onBack: () => void = () => {};

  @Local sheetVisible: boolean = false;
  @Local tts: TtsController = TtsController.instance();

  aboutToAppear(): void {
    const p: ListenParam | undefined = this.param;
    if (p === undefined || p.book === undefined || p.source === undefined || p.chapters.length === 0) {
      return;
    }
    if (this.tts.isActiveFor(p.book.bookId)) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.tts.start(ctx, p.source, p.book, p.chapters, p.chapterIndex, p.paragraphs, p.paragraphIndex);
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private minimize(): void {
    this.onBack();
  }

  private stopAndClose(): void {
    this.tts.stop();
    this.onBack();
  }

  private coverUrl(): string {
    const book = this.tts.currentBook();
    return book !== undefined ? book.coverUrl : '';
  }

  private subtitle(): string {
    const name: string = this.tts.bookName;
    const author: string = this.tts.author;
    if (author.length === 0 || name.indexOf(author) >= 0) {
      return name;
    }
    return name + ' 作者：' + author;
  }

  private speedMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const value of TTS_SPEED_OPTIONS) {
      items.push({
        value: value.toFixed(1) + 'x',
        action: () => this.tts.setSpeed(value)
      });
    }
    return items;
  }

  private timerMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const value of TTS_TIMER_OPTIONS) {
      items.push({
        value: value === 0 ? '关闭定时' : value.toString() + ' 分钟',
        action: () => this.tts.setTimer(value)
      });
    }
    return items;
  }

  private voiceMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const value of TTS_VOICE_OPTIONS) {
      items.push({
        value: voiceName(value),
        action: () => this.tts.setVoice(value)
      });
    }
    return items;
  }

  private timerLabel(): string {
    if (this.tts.timerRemain <= 0) {
      return '定时';
    }
    const m: number = Math.floor(this.tts.timerRemain / 60);
    const s: number = this.tts.timerRemain % 60;
    return (m < 10 ? '0' + m.toString() : m.toString()) + ':' + (s < 10 ? '0' + s.toString() : s.toString());
  }

  // ── UI builders ───────────────────────────────────────────────

  @Builder
  iconButton(icon: Resource, label: string, action: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([$r('app.color.listen_text')])
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(label)
    .onClick(action)
  }

  @Builder
  circleButton(icon: Resource, size: number, action: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(size * 0.42)
        .fontColor([$r('app.color.listen_text')])
    }
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .backgroundColor($r('app.color.listen_card'))
    .justifyContent(FlexAlign.Center)
    .onClick(action)
  }

  @Builder
  topBar() {
    Row() {
      this.iconButton($r('sys.symbol.chevron_down'), '收起', () => this.minimize())
      Blank()
      this.iconButton($r('sys.symbol.xmark'), '停止听书', () => this.stopAndClose())
    }
    .width('100%')
    .height(52)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  header() {
    Column() {
      BookCover({
        source: this.tts.currentSource(),
        coverUrl: this.coverUrl(),
        name: this.tts.bookName,
        coverWidth: 200,
        coverHeight: 266,
        radius: 8
      })
      Text(this.tts.chapterTitle)
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.listen_text'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 24 })
      Row() {
        Text(this.subtitle())
          .fontSize(14)
          .fontColor($r('app.color.listen_text_dim'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(22)
          .fontColor([$r('app.color.listen_text_dim')])
          .margin({ left: 12 })
          .onClick(() => {
            this.sheetVisible = true;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })
    }
    .width('100%')
  }

  @Builder
  progressBlock() {
    Column() {
      Slider({
        value: this.tts.paragraphIndex + 1,
        min: 1,
        max: Math.max(this.tts.paragraphCount, 1),
        step: 1
      })
        .width('100%')
        .trackThickness(3)
        .blockColor($r('app.color.listen_text'))
        .selectedColor($r('app.color.listen_text'))
        .trackColor($r('app.color.listen_card'))
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            const target: number = Math.round(value) - 1;
            if (target !== this.tts.paragraphIndex) {
              this.tts.seekParagraph(target);
            }
          }
        })
      Row() {
        Text(formatTime(this.tts.elapsedMs))
          .fontSize(13)
          .fontColor($r('app.color.listen_text_dim'))
        Blank()
        Text(formatTime(this.tts.estimateDurationMs()))
          .fontSize(13)
          .fontColor($r('app.color.listen_text_dim'))
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .margin({ top: 28 })
  }

  @Builder
  controls() {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.video_speed'))
          .fontSize(24)
          .fontColor([$r('app.color.listen_text')])
        Text(this.tts.speed.toFixed(1) + 'x')
          .fontSize(13)
          .fontColor($r('app.color.listen_text_dim'))
          .margin({ top: 6 })
      }
      .accessibilityText('语速')
      .bindMenu(this.speedMenuItems())

      this.circleButton($r('sys.symbol.backward_end_fill'), 52, () => this.tts.prev())

      Row() {
        SymbolGlyph(this.tts.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(34)
          .fontColor([$r('app.color.listen_play_fg')])
      }
      .width(84)
      .height(84)
      .borderRadius(42)
      .backgroundColor($r('app.color.listen_play_bg'))
      .justifyContent(FlexAlign.Center)
      .accessibilityText(this.tts.playing ? '暂停' : '播放')
      .onClick(() => this.tts.toggle())

      this.circleButton($r('sys.symbol.forward_end_fill'), 52, () => this.tts.next())

      Column() {
        SymbolGlyph($r('sys.symbol.timer_circle_fill'))
          .fontSize(24)
          .fontColor([this.tts.timerRemain > 0 ? $r('app.color.listen_text') : $r('app.color.listen_text_dim')])
        Text(this.timerLabel())
          .fontSize(13)
          .fontColor($r('app.color.listen_text_dim'))
          .margin({ top: 6 })
      }
      .accessibilityText('定时关闭')
      .bindMenu(this.timerMenuItems())
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .margin({ top: 32 })
  }

  @Builder
  voiceRow() {
    Row() {
      Text('朗读音色 · ' + voiceName(this.tts.voice))
        .fontSize(15)
        .fontColor($r('app.color.listen_text'))
      Blank()
      SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
        .fontSize(18)
        .fontColor([$r('app.color.listen_text_dim')])
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .backgroundColor($r('app.color.listen_card'))
    .borderRadius(16)
    .margin({ top: 24 })
    .accessibilityText('朗读音色')
    .bindMenu(this.voiceMenuItems())
  }

  @Builder
  tocContent() {
    Column() {
      List({ space: 0 }) {
        ForEach(this.tts.currentChapters(), (chapter: Chapter) => {
          ListItem() {
            Text(chapter.title)
              .fontSize(15)
              .fontColor(chapter.index === this.tts.chapterIndex
                ? $r('app.color.brand')
                : $r('app.color.text_1'))
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => {
                this.sheetVisible = false;
                this.tts.jumpChapter(chapter.index);
              })
          }
        }, (chapter: Chapter) => chapter.index.toString())
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  build() {
    Stack() {
      Column() {
        this.topBar()

        Scroll() {
          Column() {
            this.header()
            if (this.tts.loading) {
              LoadingProgress()
                .width(36)
                .height(36)
                .color($r('app.color.listen_text'))
                .margin({ top: 32 })
            } else {
              this.progressBlock()
              this.controls()
              this.voiceRow()
              if (this.tts.error.length > 0) {
                Text(this.tts.error)
                  .fontSize(13)
                  .fontColor($r('app.color.listen_text_dim'))
                  .margin({ top: 16 })
              }
            }
          }
          .width('100%')
          .padding({ left: 28, right: 28, top: 8, bottom: 40 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.listen_bg'))

      BottomDrawer({
        visible: this.sheetVisible,
        title: '目录',
        sheetSize: 'large',
        mode: 'overlay',
        onClose: () => {
          this.sheetVisible = false;
        }
      }) {
        this.tocContent()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.listen_bg'))
  }
}
import { common } from '@kit.AbilityKit';
import { GroupTitle, InsetDivider } from '../components/ListCells';
import {
  KEY_TTS_SPEED,
  KEY_TTS_VOICE,
  TTS_SPEED_DEFAULT,
  TTS_SPEED_OPTIONS,
  TTS_VOICE_DEFAULT,
  TTS_VOICE_OPTIONS
} from '../common/Const';
import { getNumber, putNumber } from '../common/Prefs';

function voiceLabel(person: number): string {
  return person === 21 ? '凌飞哲（男声）' : '聆小珊（女声）';
}

@ComponentV2
export struct ListeningSettingsPage {
  @Local speed: number = TTS_SPEED_DEFAULT;
  @Local voice: number = TTS_VOICE_DEFAULT;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      this.speed = getNumber(ctx, KEY_TTS_SPEED, TTS_SPEED_DEFAULT);
      this.voice = getNumber(ctx, KEY_TTS_VOICE, TTS_VOICE_DEFAULT);
    }
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private speedLabels(): string[] {
    const labels: string[] = [];
    for (const value of TTS_SPEED_OPTIONS) {
      labels.push(value.toFixed(1) + 'x');
    }
    return labels;
  }

  private speedIndex(): number {
    const idx: number = TTS_SPEED_OPTIONS.indexOf(this.speed);
    return idx >= 0 ? idx : TTS_SPEED_OPTIONS.indexOf(TTS_SPEED_DEFAULT);
  }

  private setSpeedIndex(index: number): void {
    this.speed = TTS_SPEED_OPTIONS[index];
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_TTS_SPEED, this.speed);
    }
  }

  private setVoice(person: number): void {
    this.voice = person;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_TTS_VOICE, person);
    }
  }

  @Builder
  chips(labels: string[], selected: number, onSelect: (index: number) => void) {
    Row({ space: 8 }) {
      ForEach(labels, (label: string, index: number) => {
        Text(label)
          .fontSize(14)
          .fontWeight(index === selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(index === selected ? $r('app.color.on_brand') : $r('app.color.text_2'))
          .backgroundColor(index === selected ? $r('app.color.brand') : $r('app.color.bg_pill'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(34)
          .borderRadius(17)
          .onClick(() => onSelect(index))
      }, (label: string, index: number) => index.toString() + '_' + label)
    }
    .width('100%')
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '听书' })

          Text('默认语速')
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 10 })
          Column() {
            this.chips(this.speedLabels(), this.speedIndex(), (index: number) => this.setSpeedIndex(index))
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 12 })
          InsetDivider()

          Text('默认音色')
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 10 })
          Row({ space: 8 }) {
            ForEach(TTS_VOICE_OPTIONS, (person: number) => {
              Text(voiceLabel(person))
                .fontSize(14)
                .fontWeight(person === this.voice ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(person === this.voice ? $r('app.color.on_brand') : $r('app.color.text_2'))
                .backgroundColor(person === this.voice ? $r('app.color.brand') : $r('app.color.bg_pill'))
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height(36)
                .borderRadius(18)
                .onClick(() => this.setVoice(person))
            }, (person: number) => person.toString())
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 12 })

          Text('音色与语速为下次开始听书的默认值；男声需系统已下载该音色。后台播放与锁屏控制在开始听书后自动生效。')
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })
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
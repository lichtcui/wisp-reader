import { common } from '@kit.AbilityKit';
import { GroupTitle, InsetDivider } from '../components/ListCells';
import {
  KEY_TTS_SPEED,
  KEY_TTS_VOICE,
  KEY_TTS_ENGINE,
  KEY_TTS_SERVER,
  KEY_TTS_API_KEY,
  KEY_TTS_REMOTE_VOICE,
  TTS_SPEED_DEFAULT,
  TTS_SPEED_OPTIONS,
  TTS_VOICE_DEFAULT,
  TTS_VOICE_OPTIONS,
  TTS_ENGINE_SYSTEM,
  TTS_ENGINE_REMOTE,
  TTS_SERVER_DEFAULT,
  TTS_API_KEY_DEFAULT,
  TTS_REMOTE_VOICE_DEFAULT,
  TTS_REMOTE_VOICE_OPTIONS,
  normalizeRemoteVoice
} from '../common/Const';
import { getNumber, putNumber, getString, putString } from '../common/Prefs';

function voiceLabel(person: number): string {
  return person === 21 ? '凌飞哲（男声）' : '聆小珊（女声）';
}

@ComponentV2
export struct ListeningSettingsPage {
  @Local speed: number = TTS_SPEED_DEFAULT;
  @Local voice: number = TTS_VOICE_DEFAULT;
  @Local engine: number = TTS_ENGINE_SYSTEM;
  @Local serverUrl: string = TTS_SERVER_DEFAULT;
  @Local apiKey: string = TTS_API_KEY_DEFAULT;
  @Local remoteVoice: string = TTS_REMOTE_VOICE_DEFAULT;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      this.speed = getNumber(ctx, KEY_TTS_SPEED, TTS_SPEED_DEFAULT);
      this.voice = getNumber(ctx, KEY_TTS_VOICE, TTS_VOICE_DEFAULT);
      this.engine = getNumber(ctx, KEY_TTS_ENGINE, TTS_ENGINE_SYSTEM);
      this.serverUrl = getString(ctx, KEY_TTS_SERVER, TTS_SERVER_DEFAULT);
      this.apiKey = getString(ctx, KEY_TTS_API_KEY, TTS_API_KEY_DEFAULT);
      this.remoteVoice = normalizeRemoteVoice(getString(ctx, KEY_TTS_REMOTE_VOICE, TTS_REMOTE_VOICE_DEFAULT));
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

  private setEngine(kind: number): void {
    this.engine = kind;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_TTS_ENGINE, kind);
    }
  }

  private setServerUrl(value: string): void {
    this.serverUrl = value.trim();
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putString(ctx, KEY_TTS_SERVER, this.serverUrl);
    }
  }

  private setApiKey(value: string): void {
    this.apiKey = value;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putString(ctx, KEY_TTS_API_KEY, value);
    }
  }

  private setRemoteVoice(voice: string): void {
    this.remoteVoice = voice;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putString(ctx, KEY_TTS_REMOTE_VOICE, voice);
    }
  }

  private engineLabel(kind: number): string {
    return kind === TTS_ENGINE_REMOTE ? '远端' : '系统 TTS';
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

          Text('朗读引擎')
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 10 })
          Row({ space: 8 }) {
            ForEach([TTS_ENGINE_SYSTEM, TTS_ENGINE_REMOTE], (kind: number) => {
              Text(this.engineLabel(kind))
                .fontSize(14)
                .fontWeight(kind === this.engine ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(kind === this.engine ? $r('app.color.on_brand') : $r('app.color.text_2'))
                .backgroundColor(kind === this.engine ? $r('app.color.brand') : $r('app.color.bg_pill'))
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height(36)
                .borderRadius(18)
                .onClick(() => this.setEngine(kind))
            }, (kind: number) => kind.toString())
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 12 })
          InsetDivider()

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

          if (this.engine === TTS_ENGINE_REMOTE) {
            Text('服务器地址')
              .fontSize(16)
              .fontColor($r('app.color.text_1'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 10 })
            TextInput({ placeholder: 'http://100.x.y.z:9880', text: this.serverUrl })
              .height(44)
              .fontSize(14)
              .fontColor($r('app.color.text_1'))
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(22)
              .margin({ left: 16, right: 16, bottom: 12 })
              .onChange((value: string) => this.setServerUrl(value))

            Text('API Key（留空则不鉴权）')
              .fontSize(16)
              .fontColor($r('app.color.text_1'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 10 })
            TextInput({ placeholder: 'X-API-Key', text: this.apiKey })
              .height(44)
              .fontSize(14)
              .fontColor($r('app.color.text_1'))
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(22)
              .margin({ left: 16, right: 16, bottom: 12 })
              .onChange((value: string) => this.setApiKey(value))

            InsetDivider()
          }

          Text(this.engine === TTS_ENGINE_REMOTE ? '远端音色' : '默认音色')
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 10 })
          if (this.engine === TTS_ENGINE_REMOTE) {
            Row({ space: 8 }) {
              ForEach(TTS_REMOTE_VOICE_OPTIONS, (voice: string) => {
                Text(voice)
                  .fontSize(14)
                  .fontWeight(voice === this.remoteVoice ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(voice === this.remoteVoice ? $r('app.color.on_brand') : $r('app.color.text_2'))
                  .backgroundColor(voice === this.remoteVoice ? $r('app.color.brand') : $r('app.color.bg_pill'))
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .height(36)
                  .borderRadius(18)
                  .onClick(() => this.setRemoteVoice(voice))
              }, (voice: string) => voice)
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 12 })
          } else {
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
          }

          Text(this.engine === TTS_ENGINE_REMOTE
            ? '远端为 VPS 上的钟离/甘雨/胡桃/刻晴/雷电将军 5 个声线（音色名只是标签），需可访问填入的服务器；失败自动回退系统 TTS。'
            : '音色与语速为下次开始听书的默认值；男声需系统已下载该音色。后台播放与锁屏控制在开始听书后自动生效。')
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
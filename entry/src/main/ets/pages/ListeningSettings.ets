import { common } from '@kit.AbilityKit';
import { GroupTitle, InsetDivider } from '../components/ListCells';
import {
  KEY_TTS_SPEED,
  KEY_TTS_VOICE,
  KEY_TTS_SERVER,
  KEY_TTS_API_KEY,
  TTS_SPEED_DEFAULT,
  TTS_SPEED_OPTIONS,
  TTS_VOICE_DEFAULT,
  TTS_VOICE_OPTIONS,
  TTS_ENGINE_SYSTEM,
  TTS_SERVER_DEFAULT,
  TTS_API_KEY_DEFAULT,
  KEY_TTS_PREGEN_VOICE,
  KEY_TTS_PREGEN_AHEAD,
  KEY_TTS_PREGEN_WIFI_ONLY,
  KEY_TTS_PREGEN_PREFER,
  TTS_PREGEN_VOICE_DEFAULT,
  TTS_PREGEN_VOICE_OPTIONS,
  TTS_PREGEN_AHEAD_DEFAULT,
  TTS_PREGEN_AHEAD_OPTIONS,
  TTS_PREGEN_WIFI_ONLY_DEFAULT,
  TTS_PREGEN_PREFER_DEFAULT,
  normalizePregenVoice,
  effectiveSpeed
} from '../common/Const';
import { getNumber, putNumber, getString, putString, getBoolean, putBoolean } from '../common/Prefs';
import { TtsController } from '../model/TtsController';

function voiceLabel(person: number): string {
  return person === 21 ? '凌飞哲（男声）' : '聆小珊（女声）';
}

@ComponentV2
export struct ListeningSettingsPage {
  @Local speed: number = TTS_SPEED_DEFAULT;
  @Local voice: number = TTS_VOICE_DEFAULT;
  @Local serverUrl: string = TTS_SERVER_DEFAULT;
  @Local apiKey: string = TTS_API_KEY_DEFAULT;
  @Local pregenVoice: string = TTS_PREGEN_VOICE_DEFAULT;
  @Local pregenAhead: number = TTS_PREGEN_AHEAD_DEFAULT;
  @Local pregenWifiOnly: boolean = TTS_PREGEN_WIFI_ONLY_DEFAULT;
  @Local pregenPrefer: boolean = TTS_PREGEN_PREFER_DEFAULT;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      this.speed = getNumber(ctx, KEY_TTS_SPEED, TTS_SPEED_DEFAULT);
      this.voice = getNumber(ctx, KEY_TTS_VOICE, TTS_VOICE_DEFAULT);
      this.serverUrl = getString(ctx, KEY_TTS_SERVER, TTS_SERVER_DEFAULT);
      this.apiKey = getString(ctx, KEY_TTS_API_KEY, TTS_API_KEY_DEFAULT);
      this.pregenVoice = normalizePregenVoice(getString(ctx, KEY_TTS_PREGEN_VOICE, TTS_PREGEN_VOICE_DEFAULT));
      this.pregenAhead = getNumber(ctx, KEY_TTS_PREGEN_AHEAD, TTS_PREGEN_AHEAD_DEFAULT);
      this.pregenWifiOnly = getBoolean(ctx, KEY_TTS_PREGEN_WIFI_ONLY, TTS_PREGEN_WIFI_ONLY_DEFAULT);
      this.pregenPrefer = getBoolean(ctx, KEY_TTS_PREGEN_PREFER, TTS_PREGEN_PREFER_DEFAULT);
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
    // 实时恒为系统 TTS（D17），语速档位不再有远端那份限制
    const active: number = effectiveSpeed(this.speed, TTS_ENGINE_SYSTEM);
    const idx: number = TTS_SPEED_OPTIONS.indexOf(active);
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

  // ── 预生成设置（D17 后与朗读引擎无关，始终可见；契约见 TTS-PREGEN-IMPL §3.1）──

  private setPregenVoice(voice: string): void {
    this.pregenVoice = voice;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putString(ctx, KEY_TTS_PREGEN_VOICE, voice);
    }
  }

  private setPregenAhead(value: number): void {
    this.pregenAhead = value;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putNumber(ctx, KEY_TTS_PREGEN_AHEAD, value);
    }
  }

  private setPregenWifiOnly(isOn: boolean): void {
    this.pregenWifiOnly = isOn;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putBoolean(ctx, KEY_TTS_PREGEN_WIFI_ONLY, isOn);
    }
    TtsController.instance().setPregenWifiOnly(isOn);
  }

  /** 开了之后下一次进章生效（正在听的会话也同步，不然收碗前还会预取下一章）。 */
  private setPregenPrefer(isOn: boolean): void {
    this.pregenPrefer = isOn;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx !== undefined) {
      putBoolean(ctx, KEY_TTS_PREGEN_PREFER, isOn);
    }
    TtsController.instance().setPregenPrefer(isOn);
  }

  private aheadLabels(): string[] {
    const labels: string[] = [];
    for (const value of TTS_PREGEN_AHEAD_OPTIONS) {
      labels.push(value.toString() + ' 章');
    }
    return labels;
  }

  private pregenVoiceIndex(): number {
    const idx: number = TTS_PREGEN_VOICE_OPTIONS.indexOf(this.pregenVoice);
    return idx >= 0 ? idx : TTS_PREGEN_VOICE_OPTIONS.indexOf(TTS_PREGEN_VOICE_DEFAULT);
  }

  private pregenAheadIndex(): number {
    const idx: number = TTS_PREGEN_AHEAD_OPTIONS.indexOf(this.pregenAhead);
    return idx >= 0 ? idx : TTS_PREGEN_AHEAD_OPTIONS.indexOf(TTS_PREGEN_AHEAD_DEFAULT);
  }

  private noDisabled(count: number): boolean[] {
    const flags: boolean[] = [];
    for (let i = 0; i < count; i++) {
      flags.push(false);
    }
    return flags;
  }

  @Builder
  chips(labels: string[], selected: number, onSelect: (index: number) => void, disabled: boolean[]) {
    Row({ space: 8 }) {
      ForEach(labels, (label: string, index: number) => {
        Text(label)
          .fontSize(14)
          .fontWeight(index === selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(index === selected && !disabled[index]
            ? $r('app.color.on_brand')
            : (disabled[index] ? $r('app.color.text_4') : $r('app.color.text_2')))
          .backgroundColor(index === selected && !disabled[index]
            ? $r('app.color.brand')
            : $r('app.color.bg_pill'))
          .opacity(disabled[index] ? 0.45 : 1)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(34)
          .borderRadius(17)
          .onClick(() => {
            if (!disabled[index]) {
              onSelect(index);
            }
          })
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
            this.chips(this.speedLabels(), this.speedIndex(), (index: number) => this.setSpeedIndex(index),
              this.noDisabled(TTS_SPEED_OPTIONS.length))
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

          Text('音色与语速为下次开始听书的默认值；男声需系统已下载该音色。后台播放与锁屏控制在开始听书后自动生效。'
            + '未预生成的章节用系统 TTS 实时朗读（16 kHz）。')
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })

          GroupTitle({ text: '预生成音频（电脑端 VPS 后台合成）' })

          Text('服务器地址')
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 10 })
          TextInput({ placeholder: 'http://100.x.y.z:39680', text: this.serverUrl })
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

          Text('预生成音色（缓存章用这个声音）')
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 10 })
          Column() {
            this.chips(TTS_PREGEN_VOICE_OPTIONS, this.pregenVoiceIndex(),
              (index: number) => this.setPregenVoice(TTS_PREGEN_VOICE_OPTIONS[index]),
              this.noDisabled(TTS_PREGEN_VOICE_OPTIONS.length))
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 12 })
          InsetDivider()

          Text('提前生成章数')
            .fontSize(16)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 10 })
          Column() {
            this.chips(this.aheadLabels(), this.pregenAheadIndex(),
              (index: number) => this.setPregenAhead(TTS_PREGEN_AHEAD_OPTIONS[index]),
              this.noDisabled(TTS_PREGEN_AHEAD_OPTIONS.length))
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 12 })
          InsetDivider()

          Row() {
            Text('仅 Wi-Fi 时预生成')
              .fontSize(16)
              .fontColor($r('app.color.text_1'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.pregenWifiOnly })
              .selectedColor($r('app.color.brand'))
              .onChange((isOn: boolean) => this.setPregenWifiOnly(isOn))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          InsetDivider()

          Row() {
            Text('缓存优先播放')
              .fontSize(16)
              .fontColor($r('app.color.text_1'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.pregenPrefer })
              .selectedColor($r('app.color.brand'))
              .onChange((isOn: boolean) => this.setPregenPrefer(isOn))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })

          Text('预生成由电脑端（VPS）在你听书时后台合成：每章约 1 小时算力、单章约 31 MB 空间。'
            + '缓存就绪的章节用上面的预生成音色（24 kHz），未就绪的章节用系统 TTS 实时朗读（16 kHz），同一章内不会换声线。'
            + '实时链路不再走服务器（远端 VITS 已停用）；听完的章节会立刻删掉缓存，关掉「缓存优先播放」可强制走实时（排查用）。')
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 0, bottom: 16 })
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

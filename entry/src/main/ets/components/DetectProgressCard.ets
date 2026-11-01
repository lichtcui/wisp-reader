import {
  DETECT_MODE_FULL,
  DETECT_MODE_PROBE,
  DETECT_STATUS_CANCELLED,
  DETECT_STATUS_DONE,
  DETECT_STATUS_FAILED,
  DETECT_STATUS_RUNNING
} from '../model/DetectJob';

/**
 * 书源管理页的「任务态」主体：检测进行 / 结束时它取代书源列表。
 *
 * 页面持有作业状态（`DetectJobRunner` 单例），本组件只渲染——
 * 一次检测只出现在一个地方，不再有「底部作业条 + 检测段作业卡」两份进度。
 * 布局与入口约定见 docs/specs/SPEC-BOOKSOURCE-LAYOUT.md §3.3。
 */
@ComponentV2
export struct DetectProgressCard {
  @Param status: string = '';
  @Param mode: string = DETECT_MODE_FULL;
  @Param total: number = 0;
  @Param done: number = 0;
  @Param startedAt: number = 0;
  @Param updatedAt: number = 0;
  @Param message: string = '';
  @Param backgroundState: string = 'inactive';
  @Param clockNow: number = 0;
  @Param launching: boolean = false;
  @Param canResume: boolean = false;
  /** 当前不可用源条数（整库口径，与一键清理的作用域一致）。 */
  @Param unavailableCount: number = 0;

  @Event onCancel: () => void = () => {};
  @Event onResume: () => void = () => {};
  @Event onBack: () => void = () => {};
  @Event onDisableUnavailable: () => void = () => {};
  @Event onDeleteUnavailable: () => void = () => {};

  private running(): boolean {
    return this.status === DETECT_STATUS_RUNNING;
  }

  private modeLabel(): string {
    return this.mode === DETECT_MODE_PROBE ? '预检' : '完整检测';
  }

  private title(): string {
    if (this.running()) {
      return '检测中 · ' + this.modeLabel();
    }
    if (this.status === DETECT_STATUS_DONE) {
      return '检测完成 · ' + this.modeLabel();
    }
    if (this.status === DETECT_STATUS_CANCELLED) {
      return '已取消 · ' + this.modeLabel();
    }
    if (this.status === DETECT_STATUS_FAILED) {
      return '检测失败 · ' + this.modeLabel();
    }
    return this.modeLabel();
  }

  private dotColor(): ResourceColor {
    if (this.running()) {
      return $r('app.color.info');
    }
    if (this.status === DETECT_STATUS_FAILED) {
      return $r('app.color.warning');
    }
    if (this.status === DETECT_STATUS_DONE) {
      return $r('app.color.brand');
    }
    return $r('app.color.text_4');
  }

  private progressTotal(): number {
    return this.total > 0 ? this.total : 1;
  }

  private elapsedMs(): number {
    if (this.startedAt <= 0) {
      return 0;
    }
    const end: number = this.running() && this.clockNow > 0 ? this.clockNow : this.updatedAt;
    return Math.max(0, end - this.startedAt);
  }

  private remainingMs(): number {
    if (!this.running() || this.done <= 0 || this.total <= this.done) {
      return 0;
    }
    return Math.floor(this.elapsedMs() * (this.total - this.done) / this.done);
  }

  private pad2(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }

  private durationText(ms: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(ms / 1000));
    const hours: number = Math.floor(totalSeconds / 3600);
    const minutes: number = Math.floor((totalSeconds % 3600) / 60);
    const seconds: number = totalSeconds % 60;
    if (hours > 0) {
      return hours.toString() + ':' + this.pad2(minutes) + ':' + this.pad2(seconds);
    }
    return this.pad2(minutes) + ':' + this.pad2(seconds);
  }

  private backgroundLabel(): string {
    if (this.backgroundState === 'degraded') {
      return '后台任务不可用，离开应用会暂停';
    }
    if (this.backgroundState === 'active') {
      return '后台继续运行';
    }
    if (this.backgroundState === 'requesting') {
      return '正在申请后台运行';
    }
    return '仅前台运行';
  }

  private cancelText(): string {
    if (this.launching) {
      return '正在停止…';
    }
    return '取消检测';
  }

  /**
   * 取消 / 失败轮次可能被续跑。`canResume()` 要等 `runningTask` 释放后才为真（真机实测约 1s），
   * 若按它切换布局，按钮位置会在取消后跳一次，用户可能误点到「继续本轮」——
   * 因此这两态**固定**渲染双按钮，只把「继续本轮」置灰。
   */
  private resumable(): boolean {
    return this.status === DETECT_STATUS_CANCELLED || this.status === DETECT_STATUS_FAILED;
  }

  private doneSummary(): string {
    const head: string = '本轮已检测 ' + this.done.toString() + ' 个书源';
    if (this.unavailableCount > 0) {
      return head + '；当前 ' + this.unavailableCount.toString() + ' 个不可用，已排到列表最前。';
    }
    return head + '；没有不可用书源。';
  }

  private cancelledSummary(): string {
    return '已保留本轮结果。' + (this.canResume ? '继续时只处理剩余书源。' : '重新开始会建立新一轮。');
  }

  @Builder
  statusLine() {
    if (this.running()) {
      Row() {
        Text(this.backgroundLabel())
          .fontSize(12)
          .fontColor(this.backgroundState === 'degraded' ?
            $r('app.color.warning') : $r('app.color.text_4'))
        Blank()
        if (this.remainingMs() > 0) {
          Text('预计剩余 ' + this.durationText(this.remainingMs()))
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
        }
      }
      .width('100%')
    } else if (this.status === DETECT_STATUS_DONE) {
      Text(this.doneSummary())
        .fontSize(12)
        .fontColor($r('app.color.text_4'))
        .width('100%')
    } else if (this.status === DETECT_STATUS_CANCELLED) {
      Text(this.cancelledSummary())
        .fontSize(12)
        .fontColor($r('app.color.text_4'))
        .width('100%')
    } else if (this.status === DETECT_STATUS_FAILED) {
      Text(this.message.length > 0 ? this.message : '检测作业失败，可继续处理剩余书源。')
        .fontSize(12)
        .fontColor($r('app.color.warning'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  @Builder
  actions() {
    if (this.running()) {
      Button(this.cancelText())
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor($r('app.color.text_2'))
        .backgroundColor($r('app.color.bg_pill'))
        .borderRadius(20)
        .enabled(!this.launching)
        .accessibilityText(this.cancelText())
        .onClick(() => this.onCancel())
    } else if (this.resumable()) {
      Row({ space: 10 }) {
        Button('继续本轮')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(20)
          .enabled(!this.launching && this.canResume)
          .accessibilityText('继续本轮检测')
          .onClick(() => this.onResume())
        Button('返回书源列表')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor($r('app.color.text_2'))
          .backgroundColor($r('app.color.bg_pill'))
          .borderRadius(20)
          .accessibilityText('返回书源列表')
          .onClick(() => this.onBack())
      }
      .width('100%')
    } else {
      Button('返回书源列表')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor($r('app.color.on_brand'))
        .backgroundColor($r('app.color.brand'))
        .borderRadius(20)
        .enabled(!this.launching)
        .accessibilityText('返回书源列表')
        .onClick(() => this.onBack())
    }
  }

  @Builder
  cleanupActions() {
    if (!this.running() && this.unavailableCount > 0) {
      Row({ space: 10 }) {
        Button('关闭不可用 ' + this.unavailableCount.toString())
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .fontColor($r('app.color.text_2'))
          .backgroundColor($r('app.color.bg_pill'))
          .borderRadius(18)
          .enabled(!this.launching)
          .accessibilityText('关闭不可用书源')
          .onClick(() => this.onDisableUnavailable())
        Button('删除不可用 ' + this.unavailableCount.toString())
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .fontColor($r('app.color.warning'))
          .backgroundColor($r('app.color.bg_pill'))
          .borderRadius(18)
          .enabled(!this.launching)
          .accessibilityText('删除不可用书源')
          .onClick(() => this.onDeleteUnavailable())
      }
      .width('100%')
    }
  }

  build() {
    Column() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Row()
            .width(7)
            .height(7)
            .borderRadius(4)
            .backgroundColor(this.dotColor())
          Text(this.title())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_1'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.startedAt > 0) {
            Text(this.durationText(this.elapsedMs()))
              .fontSize(12)
              .fontColor($r('app.color.text_4'))
          }
        }
        .width('100%')

        Row({ space: 10 }) {
          Progress({
            value: this.done,
            total: this.progressTotal(),
            type: ProgressType.Linear
          })
            .layoutWeight(1)
            .height(6)
            .color($r('app.color.brand'))
            .backgroundColor($r('app.color.bg_pill'))
          Text(this.done.toString() + ' / ' + this.total.toString())
            .fontSize(12)
            .fontColor($r('app.color.text_3'))
        }
        .width('100%')
        .accessibilityText(this.title() + '，已完成 ' + this.done.toString() + ' / ' + this.total.toString())
        .accessibilityLevel('yes')

        this.statusLine()
        this.actions()
        this.cleanupActions()
      }
      .width('100%')
      .padding(14)
      .margin({ left: 16, right: 16 })
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(10)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
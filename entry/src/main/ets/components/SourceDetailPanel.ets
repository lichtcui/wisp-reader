import { sourceRowStateLabel } from './SourceRows';

export interface SourceRuleField {
  label: string;
  value: string;
}

export interface SourceDetailData {
  id: number;
  name: string;
  url: string;
  group: string;
  enabled: boolean;
  detectState: string;
  respondMs: number;
  detectAt: string;
  rules: SourceRuleField[];
}

@ComponentV2
export struct SourceDetailPanel {
  @Param detail: SourceDetailData | undefined = undefined;
  @Param loading: boolean = false;
  @Param failed: boolean = false;
  @Event onDelete: () => void = () => {};
  private detailScroller: Scroller = new Scroller();

  @Monitor('detail')
  onDetailChanged(): void {
    setTimeout((): void => {
      this.detailScroller.scrollEdge(Edge.Top);
    }, 0);
  }

  private stateColor(state: string): ResourceColor {
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

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_3'))
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_1'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  stateRow(detail: SourceDetailData) {
    Row() {
      Text('最近检测')
        .fontSize(14)
        .fontColor($r('app.color.text_3'))
      Blank()
      Text(sourceRowStateLabel(detail.detectState))
        .fontSize(12)
        .fontColor(this.stateColor(detail.detectState))
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .backgroundColor($r('app.color.bg_pill'))
        .borderRadius(10)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ruleField(field: SourceRuleField) {
    Column({ space: 6 }) {
      Text(field.label)
        .fontSize(13)
        .fontColor($r('app.color.text_3'))
        .width('100%')
      Text(field.value)
        .fontSize(12)
        .fontColor($r('app.color.text_2'))
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(10)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  detailBody(detail: SourceDetailData) {
    Text(detail.name)
      .fontSize(20)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_1'))
      .width('100%')
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .accessibilityText('书源名称：' + detail.name)
    Text(detail.url)
      .fontSize(12)
      .fontColor($r('app.color.text_4'))
      .width('100%')
      .maxLines(3)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ top: 6 })
      .accessibilityText('书源地址：' + detail.url)

    Column() {
      this.infoRow('分组', detail.group)
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
      this.infoRow('启停状态', detail.enabled ? '已启用' : '已停用')
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
      this.stateRow(detail)
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
      this.infoRow('检测耗时', detail.detectState.length > 0 ? detail.respondMs.toString() + 'ms' : '—')
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
      this.infoRow('检测时间', detail.detectAt)
    }
    .width('100%')
    .margin({ top: 8, bottom: 12 })

    Text('规则字段')
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_1'))
      .width('100%')
      .margin({ top: 4, bottom: 8 })
    Column({ space: 12 }) {
      ForEach(detail.rules, (field: SourceRuleField) => {
        this.ruleField(field)
      }, (field: SourceRuleField) => field.label)
    }
    .width('100%')

    Button('删除书源')
      .width('100%')
      .height(44)
      .fontSize(14)
      .fontColor($r('app.color.on_brand'))
      .backgroundColor($r('app.color.brand'))
      .borderRadius(22)
      .margin({ top: 20 })
      .accessibilityText('删除书源')
      .onClick(() => this.onDelete())
  }

  build() {
    Scroll(this.detailScroller) {
      Column() {
        if (this.loading) {
          Text('正在读取书源…')
            .fontSize(14)
            .fontColor($r('app.color.text_3'))
            .width('100%')
            .padding({ top: 20, bottom: 20 })
            .accessibilityText('正在读取书源')
        } else if (this.detail !== undefined) {
          this.detailBody(this.detail)
        } else {
          Text(this.failed ? '书源数据读取失败' : '未选择书源')
            .fontSize(14)
            .fontColor($r('app.color.text_3'))
            .width('100%')
            .padding({ top: 20, bottom: 20 })
            .accessibilityText(this.failed ? '书源数据读取失败' : '未选择书源')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}

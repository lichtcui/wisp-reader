import { bookEngine } from '../engine/BookEngineNapi';
import { ParseOutput, RuleDiagnostic } from '../engine/types';
import { GroupTitle, InsetDivider, SegmentedCell } from '../components/ListCells';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderPoC';

const CONTENT_TYPES: string[] = ['html', 'json'];

function kindLabel(kind: string): string {
  if (kind === 'regex') {
    return '正则';
  }
  if (kind === 'css') {
    return 'CSS 选择器';
  }
  if (kind === 'js') {
    return 'JS';
  }
  if (kind === 'unsupported') {
    return '不支持';
  }
  return kind.length > 0 ? kind : '未知';
}

@ComponentV2
export struct RuleDebuggerPage {
  @Local rule: string = '';
  @Local contentType: number = 0;
  @Local content: string = '';
  @Local values: string[] = [];
  @Local diagnostics: RuleDiagnostic[] = [];
  @Local ran: boolean = false;
  @Local errorMsg: string = '';

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async run(): Promise<void> {
    if (this.rule.trim().length === 0 || this.content.trim().length === 0) {
      this.toast('请填写规则与待解析内容');
      return;
    }
    this.errorMsg = '';
    this.ran = false;
    try {
      const output: ParseOutput = await bookEngine.parseWithDiagnostics(
        this.content,
        CONTENT_TYPES[this.contentType],
        this.rule
      );
      this.values = output.values === undefined ? [] : output.values;
      this.diagnostics = output.diagnostics === undefined ? [] : output.diagnostics;
      this.ran = true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'rule parse failed: %{public}s', JSON.stringify(err));
      this.values = [];
      this.diagnostics = [];
      this.errorMsg = '解析失败，请检查规则格式';
      this.ran = true;
    }
  }

  @Builder
  diagRow(d: RuleDiagnostic) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(kindLabel(d.kind))
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor($r('app.color.bg_pill'))
          .borderRadius(8)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)

      Text(d.rule)
        .fontSize(13)
        .fontColor($r('app.color.text_1'))
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(d.message)
        .fontSize(12)
        .fontColor($r('app.color.text_4'))
        .width('100%')
        .lineHeight(17)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '规则字段' })
          TextArea({
            placeholder: 'class.bookList.0.name@textNodes 或 ##<a href="(.+?)">##$1##',
            text: this.rule
          })
            .height(88)
            .fontSize(14)
            .fontColor($r('app.color.text_1'))
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.rule = value;
            })

          GroupTitle({ text: 'content_type' })
          Row() {
            SegmentedCell({
              options: CONTENT_TYPES,
              selected: this.contentType,
              onSelect: (index: number) => {
                this.contentType = index;
              }
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          GroupTitle({ text: '待解析内容' })
          TextArea({ placeholder: '粘贴 HTML 或 JSON 文本', text: this.content })
            .height(180)
            .fontSize(14)
            .fontColor($r('app.color.text_1'))
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.content = value;
            })

          Row() {
            Button('运行')
              .width('100%')
              .height(44)
              .fontSize(16)
              .fontColor($r('app.color.on_brand'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(22)
              .onClick(() => {
                this.run();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 20 })

          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(13)
              .fontColor($r('app.color.warning'))
              .width('100%')
              .padding({ left: 16, right: 16 })
              .margin({ top: 12 })
          }

          if (this.ran) {
            GroupTitle({ text: `提取结果（${this.values.length}）` })
            if (this.values.length === 0) {
              Text('无提取结果：规则未命中任何内容')
                .fontSize(13)
                .fontColor($r('app.color.text_4'))
                .width('100%')
                .padding({ left: 16, right: 16 })
            } else {
              Column() {
                ForEach(this.values, (v: string, index: number) => {
                  Text(v)
                    .fontSize(14)
                    .fontColor($r('app.color.text_1'))
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  if (index < this.values.length - 1) {
                    InsetDivider()
                  }
                }, (v: string, index: number) => index.toString())
              }
              .width('100%')
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(12)
              .margin({ left: 16, right: 16, top: 6 })
            }

            GroupTitle({ text: `诊断（${this.diagnostics.length}）` })
            if (this.diagnostics.length === 0) {
              Text('无诊断信息（规则解析正常）')
                .fontSize(13)
                .fontColor($r('app.color.text_4'))
                .width('100%')
                .padding({ left: 16, right: 16 })
            } else {
              Column() {
                ForEach(this.diagnostics, (d: RuleDiagnostic, index: number) => {
                  Column() {
                    this.diagRow(d)
                    if (index < this.diagnostics.length - 1) {
                      InsetDivider()
                    }
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16 })
                }, (d: RuleDiagnostic, index: number) => index.toString())
              }
              .width('100%')
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(12)
              .margin({ left: 16, right: 16, top: 6 })
            }

            Text('v1 为手粘内容调试，不从线上源自动拉取 HTML。')
              .fontSize(12)
              .fontColor($r('app.color.text_5'))
              .width('100%')
              .padding({ left: 16, right: 16 })
              .margin({ top: 20, bottom: 40 })
          }
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

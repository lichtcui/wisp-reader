import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Book, BookSource, ReadProgress } from '../engine/types';
import { loadSources, saveSources } from '../model/SourceRepository';
import { getAllProgress, getBooks, initShelf, replaceShelf } from '../model/ShelfRepository';
import { GroupTitle } from '../components/ListCells';

const BACKUP_SCHEMA_VERSION: number = 1;

interface BackupPayload {
  schemaVersion: number;
  exportedAt: number;
  sources: BookSource[];
  books: Book[];
  progress: ReadProgress[];
}

@ComponentV2
export struct BackupManagePage {
  @Local sourceCount: number = 0;
  @Local bookCount: number = 0;
  @Local progressCount: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.sourceCount = loadSources(ctx).length;
    this.bookCount = (await getBooks()).length;
    this.progressCount = (await getAllProgress()).size;
  }

  private pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  private dateStr(): string {
    const d: Date = new Date();
    return d.getFullYear().toString() + '-' + this.pad2(d.getMonth() + 1) + '-' + this.pad2(d.getDate());
  }

  private async collect(ctx: common.UIAbilityContext): Promise<BackupPayload> {
    const sources: BookSource[] = loadSources(ctx);
    const books: Book[] = await getBooks();
    const progressMap: Map<string, ReadProgress> = await getAllProgress();
    const progress: ReadProgress[] = [];
    progressMap.forEach((p: ReadProgress) => {
      progress.push(p);
    });
    const payload: BackupPayload = {
      schemaVersion: BACKUP_SCHEMA_VERSION,
      exportedAt: Date.now(),
      sources: sources,
      books: books,
      progress: progress
    };
    return payload;
  }

  private readText(uri: string): string {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = fileIo.readSync(file.fd, buffer);
      const bytes: Uint8Array = new Uint8Array(read === stat.size ? buffer : buffer.slice(0, read));
      return util.TextDecoder.create('utf-8').decodeToString(bytes);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private async doExport(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    try {
      const payload: BackupPayload = await this.collect(ctx);
      const json: string = JSON.stringify(payload, null, 2);
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = ['sourcereader_backup_' + this.dateStr() + '.json'];
      options.fileSuffixChoices = ['JSON|.json'];
      const uris: string[] = await savePicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(
        uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, json);
      } finally {
        fileIo.closeSync(file);
      }
      this.toast('备份已导出');
    } catch (err) {
      this.toast('导出失败');
    }
  }

  private async doImport(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    try {
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const uris: string[] = await viewPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const text: string = this.readText(uris[0]);
      const payload: BackupPayload = JSON.parse(text) as BackupPayload;
      if (payload === null || payload.schemaVersion !== BACKUP_SCHEMA_VERSION) {
        this.toast('备份文件版本不受支持');
        return;
      }
      const sources: BookSource[] = payload.sources;
      const books: Book[] = payload.books;
      const progress: ReadProgress[] = payload.progress;
      if (!Array.isArray(sources) || !Array.isArray(books) || !Array.isArray(progress)) {
        this.toast('备份内容不完整');
        return;
      }
      await initShelf(ctx);
      // 全量覆盖：书源整体替换（saveSources 写的就是整段 JSON），书架/进度先清表再写。
      saveSources(ctx, sources);
      await replaceShelf(books, progress);
      await this.reload();
      this.toast('已恢复：书源 ' + this.sourceCount + ' / 书架 ' + this.bookCount + ' / 进度 ' + this.progressCount);
    } catch (err) {
      this.toast('导入失败：文件无效或格式错误');
    }
  }

  private confirmImport(): void {
    this.getUIContext().showAlertDialog({
      title: '确认恢复备份',
      message: '将用备份文件全量覆盖当前书源、书架与阅读进度：现有数据会被清除，' +
        '备份中不存在的书源、书籍与进度不会被保留。是否继续？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '恢复',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.doImport();
        }
      }
    });
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '当前数据' })
          Column() {
            Row() {
              Text('书源')
                .fontSize(16)
                .fontColor($r('app.color.text_1'))
              Blank()
              Text(this.sourceCount.toString() + ' 个')
                .fontSize(14)
                .fontColor($r('app.color.text_4'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })

            Row() {
              Text('书架书籍')
                .fontSize(16)
                .fontColor($r('app.color.text_1'))
              Blank()
              Text(this.bookCount.toString() + ' 本')
                .fontSize(14)
                .fontColor($r('app.color.text_4'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })

            Row() {
              Text('阅读进度')
                .fontSize(16)
                .fontColor($r('app.color.text_1'))
              Blank()
              Text(this.progressCount.toString() + ' 条')
                .fontSize(14)
                .fontColor($r('app.color.text_4'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ left: 16, right: 16, top: 6 })

          GroupTitle({ text: '操作' })
          Row({ space: 12 }) {
            Button('导出备份')
              .layoutWeight(1)
              .height(48)
              .fontSize(16)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.bg_pill'))
              .borderRadius(24)
              .onClick(() => {
                this.doExport();
              })
            Button('导入并恢复')
              .layoutWeight(1)
              .height(48)
              .fontSize(16)
              .fontColor($r('app.color.on_brand'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(24)
              .onClick(() => {
                this.confirmImport();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6 })

          Text('备份为单一 JSON 文件，包含书源、书架书籍与阅读进度；导入会全量覆盖现有数据（备份中不存在的书源、书籍与进度将被删除）。')
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
            .lineHeight(18)
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 40 })
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
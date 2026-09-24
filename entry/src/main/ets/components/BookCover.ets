import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource } from '../engine/types';

/**
 * Cover with a red-gradient fallback. The bitmap is downloaded by the Rust
 * engine (carrying the source's headers/cookies) into the sandbox cache and
 * loaded via PixelMap — ArkTS never issues the source request itself.
 */
@ComponentV2
export struct BookCover {
  @Param source: BookSource | undefined = undefined;
  @Param coverUrl: string = '';
  @Param name: string = '';
  @Param coverWidth: number = 112;
  @Param coverHeight: number = 144;
  @Param radius: number = 8;

  @Local pixmap: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined || this.source === undefined || this.coverUrl.length === 0) {
      return;
    }
    try {
      const path: string = await bookEngine.downloadCover(this.source, this.coverUrl, ctx.cacheDir);
      const src: image.ImageSource = image.createImageSource(path);
      this.pixmap = await src.createPixelMap();
    } catch (err) {
      this.pixmap = undefined;
    }
  }

  build() {
    Stack() {
      if (this.pixmap !== undefined) {
        Image(this.pixmap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          Text(this.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_brand'))
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding(6)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .linearGradient({
          angle: 160,
          colors: [[$r('app.color.brand_grad_a'), 0], [$r('app.color.brand_grad_b'), 1]]
        })
      }
    }
    .width(this.coverWidth)
    .height(this.coverHeight)
    .borderRadius(this.radius)
    .clip(true)
    .backgroundColor($r('app.color.bg_pill'))
  }
}
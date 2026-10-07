import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource } from '../engine/types';

/**
 * Cover with a red-gradient fallback. The bitmap is downloaded by the Rust
 * engine (carrying the source's headers/cookies) into the sandbox cache and
 * loaded via PixelMap — ArkTS never issues the source request itself.
 *
 * Module-level caches keyed by cover URL avoid re-downloading and re-decoding
 * across panels/components within a session; the Rust side short-circuits a
 * download when the file is already on disk (and refuses to cache a body that
 * is not an image).
 */
const DOMAIN: number = 0x0000;
const TAG: string = 'SourceReaderCover';
const pixmapCache: Map<string, image.PixelMap> = new Map();
const pathCache: Map<string, string> = new Map();
/** Cap the decoded-bitmap cache so long browsing sessions cannot grow forever. */
const PIXMAP_LIMIT: number = 64;
/** URLs that already failed in this session — retrying them on every re-render
 * only spams the decoder. Session-scoped on purpose: the next launch retries. */
const failedCache: Set<string> = new Set();
const FAILED_LIMIT: number = 128;

function cachePixmap(url: string, pixmap: image.PixelMap): void {
  if (pixmapCache.has(url)) {
    pixmapCache.delete(url);
  }
  pixmapCache.set(url, pixmap);
  while (pixmapCache.size > PIXMAP_LIMIT) {
    const oldest: string | undefined = pixmapCache.keys().next().value;
    if (oldest === undefined) {
      break;
    }
    pixmapCache.delete(oldest);
  }
}

function markFailed(url: string): void {
  failedCache.add(url);
  while (failedCache.size > FAILED_LIMIT) {
    const oldest: string | undefined = failedCache.values().next().value;
    if (oldest === undefined) {
      break;
    }
    failedCache.delete(oldest);
  }
}
@ComponentV2
export struct BookCover {
  @Param source: BookSource | undefined = undefined;
  @Param coverUrl: string = '';
  @Param name: string = '';
  @Param coverWidth: number = 112;
  @Param coverHeight: number = 144;
  @Param radius: number = 8;
  /** Shelf edit mode: dim the cover to 72% while selected. */
  @Param dimmed: boolean = false;

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
    const cachedPixmap: image.PixelMap | undefined = pixmapCache.get(this.coverUrl);
    if (cachedPixmap !== undefined) {
      cachePixmap(this.coverUrl, cachedPixmap);
      this.pixmap = cachedPixmap;
      return;
    }
    if (failedCache.has(this.coverUrl)) {
      return;
    }
    let path: string | undefined = pathCache.get(this.coverUrl);
    try {
      if (path === undefined || !fileIo.accessSync(path)) {
        path = await bookEngine.downloadCover(this.source, this.coverUrl, ctx.cacheDir);
        pathCache.set(this.coverUrl, path);
      }
      const src: image.ImageSource = image.createImageSource(path);
      const pixmap: image.PixelMap = await src.createPixelMap();
      cachePixmap(this.coverUrl, pixmap);
      this.pixmap = pixmap;
    } catch (err) {
      // `not_image` (the URL is a page / anti-hotlink stub), a network error or a
      // decoder rejection. Show the fallback and do not ask again this session.
      hilog.warn(DOMAIN, TAG, 'cover unavailable url=%{public}s err=%{public}s', this.coverUrl,
        (err as BusinessError).message);
      markFailed(this.coverUrl);
      // A cached file the decoder cannot read is poison (an older build cached
      // HTML here): drop it so the next launch re-downloads instead of failing
      // against the same bytes on every render.
      if (path !== undefined) {
        pathCache.delete(this.coverUrl);
        try {
          fileIo.unlinkSync(path);
        } catch (unlinkErr) {
          // Already gone (e.g. the download itself failed) — nothing to clean.
        }
      }
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
    .opacity(this.dimmed ? 0.72 : 1)
  }
}
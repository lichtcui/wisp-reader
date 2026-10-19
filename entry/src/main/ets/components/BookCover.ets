import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { BookSource } from '../engine/types';
import { ENGINE_COVER_TIMEOUT_MS } from '../common/Const';

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
/** Same cover visible in multiple components at once: share one download/decode. */
const inflightLoads: Map<string, Promise<image.PixelMap | undefined>> = new Map();
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

function loadKeyOf(coverUrl: string, cacheDir: string): string {
  // Rust's disk slot is keyed by cover URL alone; use the same identity here so
  // two source objects cannot race the same file through separate loads.
  return cacheDir + '\u0000' + coverUrl;
}

async function downloadAndDecode(
  source: BookSource,
  coverUrl: string,
  cacheDir: string
): Promise<image.PixelMap | undefined> {
  let path: string | undefined = pathCache.get(coverUrl);
  let src: image.ImageSource | undefined = undefined;
  try {
    if (path === undefined || !fileIo.accessSync(path)) {
      path = await bookEngine.downloadCover(source, coverUrl, cacheDir, ENGINE_COVER_TIMEOUT_MS);
      pathCache.set(coverUrl, path);
    }
    src = image.createImageSource(path);
    const pixmap: image.PixelMap = await src.createPixelMap();
    cachePixmap(coverUrl, pixmap);
    return pixmap;
  } catch (err) {
    // `not_image` (the URL is a page / anti-hotlink stub), a network error or a
    // decoder rejection. Show the fallback and do not ask again this session.
    hilog.warn(DOMAIN, TAG, 'cover unavailable url=%{public}s err=%{public}s', coverUrl,
      (err as BusinessError).message);
    markFailed(coverUrl);
    // A cached file the decoder cannot read is poison (an older build cached
    // HTML here): drop it so the next launch re-downloads instead of failing
    // against the same bytes on every render.
    if (path !== undefined) {
      pathCache.delete(coverUrl);
      try {
        fileIo.unlinkSync(path);
      } catch (unlinkErr) {
        // Already gone (e.g. the download itself failed) — nothing to clean.
      }
    }
    return undefined;
  } finally {
    if (src !== undefined) {
      try {
        await src.release();
      } catch (releaseErr) {
        // The decoded PixelMap is independent; release failure is not a cover failure.
      }
    }
  }
}

async function obtainPixmap(
  source: BookSource,
  coverUrl: string,
  cacheDir: string
): Promise<image.PixelMap | undefined> {
  const cachedPixmap: image.PixelMap | undefined = pixmapCache.get(coverUrl);
  if (cachedPixmap !== undefined) {
    cachePixmap(coverUrl, cachedPixmap);
    return cachedPixmap;
  }
  if (failedCache.has(coverUrl)) {
    return undefined;
  }
  const key: string = loadKeyOf(coverUrl, cacheDir);
  const running: Promise<image.PixelMap | undefined> | undefined = inflightLoads.get(key);
  if (running !== undefined) {
    return await running;
  }
  const task: Promise<image.PixelMap | undefined> = downloadAndDecode(source, coverUrl, cacheDir);
  inflightLoads.set(key, task);
  try {
    return await task;
  } finally {
    // Successful loads are served by `pixmapCache`; a failed load must not remain
    // stuck in the in-flight table forever.
    inflightLoads.delete(key);
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
    this.pixmap = await obtainPixmap(this.source, this.coverUrl, ctx.cacheDir);
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

import { Chapter } from '../engine/types';

/**
 * 换源候选的「目录体检」（v1.1 追加，背景见 `docs/bugfix/TASKS.md` T-SWITCH 系列）。
 *
 * 为什么只在换源候选里做：这是全 App 唯一**已经拿到整份目录**、又还没决定用哪个源的地方
 * （`SourcePrefetch` 为了「点切换即命中」本来就会给最靠前的候选爬一遍目录），
 * 所以这次体检的**边际成本是 0**。搜索结果页要判同样的事就得给每个候选各加一次全量目录爬取
 * （`小说` 源《剑来》1321 行 1 页 / `bbiquge8` 1309 行 13 页），不值得放进搜索主路径。
 *
 * 判什么（一次 O(n) 扫描，只看目录形状，不看正文）：
 * - `dupUrls`：同一个章节 URL 被列了多次。这是**唯一在候选之间有区分度**的缺陷——
 *   真机实测《剑来》：`小说` 源把详情页顶部的「最新章节列表」预览块（最新 12 章、最新在前）
 *   也当成目录返回了，于是 `第73章…第84章` 各出现两次（1321 行 / 1309 个唯一 URL）；
 *   而 `bbiquge8` 同一本书是 1309 行 / 0 重复。所以徽标能告诉用户「这两个候选不是一样脏」。
 * - `tailRestart`：末段章号回退（`第一千二百一十八章 看书人` 之后又出现 `第1章 少年游`）。
 *   这**不是某一个源的问题**：实测 `bbiquge8` 与 `小说` 的目录都长这样，是上游采集数据
 *   本身把两次上传接在了同一本书里。所以它**不参与级别判定到可疑**（level 2），
 *   只作为提示——它的价值恰恰是告诉用户「换源不解决这个」。
 * - `dupTitles` / `notices`：站点自己的重号（`第349章` 连两行）与夹在目录里的公告
 *   （`紧急通知` / `请假一天，顺便小聊几句。`）。两者都在**两个源上同时出现**，
 *   阈值定在 3 才提示，避免把「楔子」这类正常标题算成公告。
 * - `untitled`：标题为空的行。真机实测某候选整份目录 **1331 行全都没有标题**
 *   （同一条 `chapterList = ".book_list@li"` 规则在主机 `probe parse` 上能取到 `上架感言` / `第一章 惊蛰`，
 *   设备侧为何为空**未查清**，见 `docs/bugfix/TASKS.md` §T-SWITCH-2「未解释的观测」）；
 *   不管成因在谁，这种目录在 App 里就是一列空白、换源按标题对齐进度也必然落空 ⇒
 *   与 `dupUrls` 同列可疑级（候选之间可比）。「没有章号」则另加一道闸：
 *   站点不按「第 N 章」编号时（带章号的行不到一半）不算公告 —— 否则整份目录会被读成「1331 条公告」。
 *
 * 刻意不做的事：
 * - **不解析正文**（换源候选的目录爬取是 10+ 次请求，正文体检要按章再发请求）；
 * - **不重排行**（见 `SourceSwitchPanel.queuePrefetch` 的注释：目录体检回来得晚，
 *   行序一抖动就有「手指下的行被换掉」的误点风险，改由确认框承担拦截职责）；
 * - **不写回 `sources.confidence`**（那一列是**自愈**的可达性分：成功 +5、失败扣 15–30，
 *   语义见 `SourceConfidence.ets`；目录形状不会因为搜成功而变干净，混进去会互相抵消）。
 */

/** 未见异常：不显示任何徽标。 */
export const TOC_QUALITY_CLEAN: number = 0;
/** 提示级：与换源无关的上游/站点特征（末段重新编号、重复标题、公告）。 */
export const TOC_QUALITY_NOTICE: number = 1;
/** 可疑级：同一章被列出多次——候选之间可比较，值得在切换前拦一下。 */
export const TOC_QUALITY_SUSPECT: number = 2;

/** 末段章号回退的最小前置章号：小书（几十章）正常重编号不算异常。 */
const TAIL_RESTART_MIN_CHAPTERS: number = 30;
/** 末段章号回退后至少还要有这么多行，才算「另一套编号」而不是尾章打错。 */
const TAIL_RESTART_MIN_TAIL: number = 5;
/** 重复标题 / 公告的提示阈值：低于它不给徽标（站点偶发一行不值得打扰用户）。 */
const NOTICE_THRESHOLD: number = 3;

/** 卷标记：带这些字的标题说明它自带分卷编号，不参与「末段章号回退」的判定。 */
const VOLUME_MARKERS: string[] = ['卷', '部', '篇', '册'];

const CN_DIGITS: string = '零一二三四五六七八九';

/** 目录体检结论（字段全部可显示，`level` 决定徽标文案与颜色）。 */
export class TocQuality {
  /** 目录总行数（含卷行）。 */
  rows: number = 0;
  /** 卷标题行（`isVolume` 或没有 URL）：不是章节，前面所有统计都跳过它们。 */
  volumes: number = 0;
  /** 重复 URL 的行数：同一章在目录里出现多次。 */
  dupUrls: number = 0;
  /** 重复标题的行数：URL 不同、标题相同（站点重号）。 */
  dupTitles: number = 0;
  /** 有标题但没有章节号的行数：夹在目录里的公告/请假条。 */
  notices: number = 0;
  /** 没有标题的行数（引擎给出的 `title` 为空）：这种行在 App 里就是一列空白。 */
  untitled: number = 0;
  /** 带章节号（`第` + 数字）的行数：用来判「这个源到底按不按`第 N 章`编号」。 */
  numbered: number = 0;
  /**
   * 这份目录**不按「第 N 章」编号**（带章节号的行不到一半）。
   * 此时「没有章节号」是站点的编号风格（`1. xxx` / `序章` / 只有标题），不是公告：
   * 真机实测某候选整份目录 1331 行都判不出章号，把它读成「1331 条公告」就是误报。
   */
  numberingOff: boolean = false;
  /** 末段章号回退：前半段的最大章号之后，后半段又出现远小的编号（另一次上传）。 */
  tailRestart: boolean = false;
  /** `TOC_QUALITY_*`，`SourceSwitchPanel` 据此决定文案与颜色。 */
  level: number = TOC_QUALITY_CLEAN;
}

/**
 * 整份目录大面积没有标题（≥3 行且占可读行 ≥1/4）：换源后目录就是一列空白，
 * 按标题对齐进度也必然落空 —— 这是候选之间**可比**的缺陷，所以算可疑级。
 * 零星的空行（站点偶发）不触发。
 */
export function tocTitleless(quality: TocQuality): boolean {
  const readable: number = quality.rows - quality.volumes;
  return quality.untitled >= NOTICE_THRESHOLD && quality.untitled * 4 >= readable;
}

function hasVolumeMarker(title: string): boolean {
  for (const marker of VOLUME_MARKERS) {
    if (title.indexOf(marker) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 中文数字转整数（只覆盖目录里会出现的写法：`十` / `十二` / `两百零四` / `一千二百一十八`）。
 * 遇到不认识的字符就停：宁可少算一个数，也不要让章号回退的判定建立在猜测上。
 */
export function cnNumber(text: string): number {
  let total: number = 0;
  let section: number = 0;
  let digit: number = 0;
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const d: number = CN_DIGITS.indexOf(ch);
    if (d >= 0) {
      digit = d;
      continue;
    }
    if (ch === '两') {
      digit = 2;
      continue;
    }
    if (ch === '万') {
      total = total + (section + digit) * 10000;
      section = 0;
      digit = 0;
      continue;
    }
    let unit: number = 0;
    if (ch === '十') {
      unit = 10;
    } else if (ch === '百') {
      unit = 100;
    } else if (ch === '千') {
      unit = 1000;
    } else {
      return total + section + digit;
    }
    section = section + (digit === 0 ? 1 : digit) * unit;
    digit = 0;
  }
  return total + section + digit;
}

/**
 * 是否带章号（宽松：`第` + 数字/中文数字），用于「公告」判定。
 * 放宽到不要求「章」字，是因为站点会打错：真机实测目录里就有 `第四百二十张 山水依旧`
 * （张/章）——它明明是章节行，不该被算成公告。
 */
export function hasChapterNumber(title: string): boolean {
  return /第\s*[0-9零一二三四五六七八九十百千万两]/.test(title);
}

/** 严格意义的章节标题（`第 N 章/回/节`）：只有它进入「末段章号回退」的序列。 */
export function isChapterLike(title: string): boolean {
  return /第\s*[0-9零一二三四五六七八九十百千万两]+\s*[章回节]/.test(title);
}

/** 从章节标题里取章号；取不到（公告、卷标题、自定义标题）返回 0。 */
export function chapterNumberOf(title: string): number {
  const arabic: RegExpMatchArray | null = title.match(/第\s*(\d+)\s*[章回节]/);
  if (arabic !== null) {
    return Number.parseInt(arabic[1], 10);
  }
  const chinese: RegExpMatchArray | null = title.match(/第\s*([零一二三四五六七八九十百千万两]+)\s*[章回节]/);
  if (chinese === null) {
    return 0;
  }
  return cnNumber(chinese[1]);
}

/**
 * 体检一份目录。纯函数、无 IO：输入就是 `bookEngine.toc()` 返回的数组，
 * 所以 `scripts/toc-quality-sim.py` 能直接编译这份源码跑契约断言。
 */
export function analyzeToc(chapters: Chapter[]): TocQuality {
  const quality: TocQuality = new TocQuality();
  quality.rows = chapters.length;
  const urls: Set<string> = new Set<string>();
  const titles: Set<string> = new Set<string>();
  // 参与「章号回退」判定的行：下标与章号一一对应（跳过卷行、公告与带卷标记的标题）。
  const positions: number[] = [];
  const numbers: number[] = [];

  for (let i = 0; i < chapters.length; i++) {
    const chapter: Chapter = chapters[i];
    const url: string = chapter.url.trim();
    const title: string = chapter.title.trim();
    if (chapter.isVolume === true || url.length === 0) {
      quality.volumes = quality.volumes + 1;
      continue;
    }
    if (urls.has(url)) {
      quality.dupUrls = quality.dupUrls + 1;
    } else {
      urls.add(url);
    }
    if (title.length > 0) {
      if (titles.has(title)) {
        quality.dupTitles = quality.dupTitles + 1;
      } else {
        titles.add(title);
      }
    }
    if (title.length === 0) {
      quality.untitled = quality.untitled + 1;
      continue;
    }
    if (hasChapterNumber(title)) {
      quality.numbered = quality.numbered + 1;
    } else {
      quality.notices = quality.notices + 1;
      continue;
    }
    if (!isChapterLike(title) || hasVolumeMarker(title)) {
      continue;
    }
    const number: number = chapterNumberOf(title);
    if (number > 0) {
      positions.push(i);
      numbers.push(number);
    }
  }

  // 站点不按「第 N 章」编号时，「没有章号」不是公告（真机实测：某候选整份目录 1331 行都判不出章号）。
  const readable: number = quality.rows - quality.volumes;
  quality.numberingOff = readable > 0 && quality.numbered * 2 < readable;
  if (quality.numberingOff) {
    quality.notices = 0;
  }

  // 末段章号回退：后半段出现不到前半段最大值 1/10 的章号，且其后还有一整段行。
  const half: number = Math.floor(chapters.length / 2);
  let maxBefore: number = 0;
  for (let k = 0; k < positions.length; k++) {
    if (positions[k] < half && numbers[k] > maxBefore) {
      maxBefore = numbers[k];
    }
  }
  if (maxBefore >= TAIL_RESTART_MIN_CHAPTERS) {
    for (let k = 0; k < positions.length; k++) {
      if (positions[k] >= half && numbers[k] * 10 <= maxBefore &&
        chapters.length - positions[k] >= TAIL_RESTART_MIN_TAIL) {
        quality.tailRestart = true;
        break;
      }
    }
  }

  if (quality.dupUrls > 0 || tocTitleless(quality)) {
    quality.level = TOC_QUALITY_SUSPECT;
  } else if (quality.tailRestart || quality.dupTitles >= NOTICE_THRESHOLD ||
    quality.notices >= NOTICE_THRESHOLD) {
    quality.level = TOC_QUALITY_NOTICE;
  }
  return quality;
}

/**
 * 行内徽标文案；空串 = 不显示（干净或还没体检）。
 * 只显示**一条**最值得说的：可疑级先看「整份目录没有标题」（那行在 App 里就是空白），
 * 再看重复 URL 行（候选间可比较，也最影响阅读）；提示级按「末段重新编号 → 重复标题 → 公告」取第一个命中的。
 */
export function tocQualityLabel(quality: TocQuality | undefined): string {
  if (quality === undefined || quality.level === TOC_QUALITY_CLEAN) {
    return '';
  }
  if (quality.level === TOC_QUALITY_SUSPECT) {
    if (tocTitleless(quality)) {
      return '⚠ 目录 ' + quality.untitled.toString() + ' 行没有标题';
    }
    return '⚠ 目录 ' + quality.dupUrls.toString() + ' 行重复';
  }
  if (quality.tailRestart) {
    return '目录末段重新编号';
  }
  if (quality.dupTitles >= NOTICE_THRESHOLD) {
    return '目录 ' + quality.dupTitles.toString() + ' 个重复标题';
  }
  return quality.notices >= NOTICE_THRESHOLD ? '目录含 ' + quality.notices.toString() + ' 条公告' : '';
}

/** 切换确认框里的整句说明；空串 = 无需警示。 */
export function tocQualityWarning(quality: TocQuality | undefined): string {
  if (quality === undefined || quality.level < TOC_QUALITY_SUSPECT) {
    return '';
  }
  if (tocTitleless(quality)) {
    return '该源目录有 ' + quality.untitled.toString() + ' 行没有标题，换源后目录同样显示不出章名。';
  }
  return '该源目录有 ' + quality.dupUrls.toString() + ' 行重复（同一章被列出多次），换源不会消除。';
}
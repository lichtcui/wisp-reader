/** 分页结果的原子片段：某章某段的 [start, end) 区间落在一页上。 */
export class PageSeg {
  /** 所属章节在 chapters 里的下标（跨章连续页流需要据此取对应章的段落文本）。 */
  chapterIndex: number;
  para: number;
  start: number;
  end: number;

  constructor(chapterIndex: number, para: number, start: number, end: number) {
    this.chapterIndex = chapterIndex;
    this.para = para;
    this.start = start;
    this.end = end;
  }
}

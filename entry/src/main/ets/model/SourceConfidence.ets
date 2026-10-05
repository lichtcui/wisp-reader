import { BookSource, SourceStatus } from '../engine/types';

/**
 * 书源置信度：0–100，由搜索结果动态维护并持久化（preferences）。
 * - 失败（server_error / blocked / network_error / timeout）扣分；
 * - 搜索成功回分（封顶 100、下限 0）；
 * - 其他情况（no_results 等「源可用但无结果」）不计分。
 * 缺省（历史/内置源无该字段）视为满分 100。
 */
export const CONFIDENCE_MAX: number = 100;
export const CONFIDENCE_MIN: number = 0;
export const CONFIDENCE_DEFAULT: number = CONFIDENCE_MAX;

/** 越严重扣得越多（站点级故障 > 临时故障）。 */
function penaltyFor(error: string): number {
  switch (error) {
    case 'blocked':
      return 30;
    case 'server_error':
      return 25;
    case 'network_error':
      return 20;
    case 'timeout':
      return 15;
    default:
      return 0;
  }
}

const SUCCESS_REWARD: number = 5;

export function confidenceOf(source: BookSource): number {
  const c: number | undefined = source.confidence;
  return c === undefined ? CONFIDENCE_DEFAULT : c;
}

function clamp(v: number): number {
  if (v > CONFIDENCE_MAX) {
    return CONFIDENCE_MAX;
  }
  if (v < CONFIDENCE_MIN) {
    return CONFIDENCE_MIN;
  }
  return v;
}

/** 返回按置信度从高到低排序的新数组（不影响入参）。 */
export function sortByConfidence(sources: BookSource[]): BookSource[] {
  const copy: BookSource[] = sources.slice();
  copy.sort((a: BookSource, b: BookSource): number => confidenceOf(b) - confidenceOf(a));
  return copy;
}

/**
 * 把一轮搜索的结果套用到对应书源的置信度上（按 sourceUrl 匹配），
 * 原地修改并返回 `sources`，由调用方负责持久化。
 */
export function applyOutcomes(sources: BookSource[], statuses: SourceStatus[]): BookSource[] {
  const byUrl: Map<string, SourceStatus> = new Map<string, SourceStatus>();
  for (const st of statuses) {
    byUrl.set(st.sourceUrl, st);
  }
  for (const src of sources) {
    const st: SourceStatus | undefined = byUrl.get(src.bookSourceUrl);
    if (st === undefined) {
      continue;
    }
    const base: number = confidenceOf(src);
    let next: number = base;
    if (st.ok) {
      next = base + SUCCESS_REWARD;
    } else {
      next = base - penaltyFor(st.error);
    }
    src.confidence = clamp(next);
  }
  return sources;
}
import { BookSource, SourceStatus } from '../engine/types';

/**
 * 书源置信度：0–100，由搜索结果动态维护，`sources.confidence` 列是唯一权威存储。
 * - 失败（server_error / blocked / network_error / timeout）扣分；
 * - 搜索成功回分（封顶 100、下限 0）；
 * - 其他情况（no_results 等「源可用但无结果」）不计分。
 * 缺省（历史/内置源无该字段）视为满分 100。
 */
export const CONFIDENCE_MAX: number = 100;
export const CONFIDENCE_MIN: number = 0;
export const CONFIDENCE_DEFAULT: number = CONFIDENCE_MAX;

/** 越严重扣得越多（站点级故障 > 临时故障）。同时被源状态抽屉用于「按置信度影响」排序分组。 */
export function penaltyFor(error: string): number {
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

/** 单个源在一轮搜索后的新置信度：成功回分，可判定的失败扣分，其余保持。 */
export function confidenceAfterStatus(base: number, status: SourceStatus): number {
  const next: number = status.ok ? base + SUCCESS_REWARD : base - penaltyFor(status.error);
  return clamp(next);
}

/** 返回按置信度从高到低排序的新数组（不影响入参）。 */
export function sortByConfidence(sources: BookSource[]): BookSource[] {
  const copy: BookSource[] = sources.slice();
  copy.sort((a: BookSource, b: BookSource): number => confidenceOf(b) - confidenceOf(a));
  return copy;
}

/**
 * 把一轮搜索的结果套用到对应书源的置信度上（按 sourceUrl 匹配），
 * 原地修改并返回 `sources`；调用方只把变化项交给 `SourceStore.patchConfidences`。
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
    src.confidence = confidenceAfterStatus(base, st);
  }
  return sources;
}

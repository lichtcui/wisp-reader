import { SourceRow } from './SourceStore';

/** Validation results for the temporary 3000-source JSON file. */
export interface T16DatasetStats {
  rows: number;
  groups: number;
  duplicateUrls: number;
  enabled: number;
  disabled: number;
}

/** One-time seed measurements. The backup is written before the table is cleared. */
export interface T16SeedResult {
  backupRows: number;
  upsertMs: number;
  added: number;
  updated: number;
  setEnabledMs: number;
  removeMs: number;
  rowsAfterRemove: number;
  twinRemained: boolean;
  stats: T16DatasetStats;
  dataPath: string;
  backupPath: string;
}

/** Projection readiness measured from the first rendered frame. */
export interface T16ReadyResult {
  rows: SourceRow[];
  initMs: number;
  listMs: number;
  totalMs: number;
}

/** Restore outcome, including an exact JSON round-trip check when possible. */
export interface T16RestoreResult {
  rows: number;
  exact: boolean;
}

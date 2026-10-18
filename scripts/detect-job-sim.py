#!/usr/bin/env python3
"""Host contract checks for the pure detect-job state machine.

The test imports the real `model/DetectJob.ets` source, not a copy. ArkTS-only
import lines are stripped and the one shared constant is sliced from
`common/Const.ets` before tsc compiles the result.
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = '/tmp/detect-job-sim'
TSC_CANDIDATES = [
    '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/bin/tsc',
    '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/bin/tsc',
]

TEST = r"""
declare const console: { log(message: string): void };
declare const process: { exitCode?: number };

let passed: number = 0;
const failures: string[] = [];
function ok(cond: boolean, label: string): void {
  if (cond) { passed++; return; }
  failures.push(label);
}
function eq(actual: unknown, expect: unknown, label: string): void {
  ok(actual === expect, label + ' (expected ' + JSON.stringify(expect) + ', got ' + JSON.stringify(actual) + ')');
}

// Frozen field contract for T4.3 / T5.2.
eq(DETECT_JOB_TRACE_FIELDS.map((f: DetectJobTraceField) => f.name).join(','),
  'status,mode,keyword,total,done,cursor,batchSize,startedAt,updatedAt,fingerprint,message',
  'trace field names are frozen');
for (const field of DETECT_JOB_TRACE_FIELDS) {
  ok(field.semantics.length > 0, 'trace field has semantics: ' + field.name);
}

// Fingerprint is a set digest and includes mode + keyword.
const fpA = computeDetectFingerprint([' 2 ', '1', '2', ''], 'probe', '重生');
const fpB = computeDetectFingerprint(['1', '2'], 'probe', '重生');
eq(fpA, fpB, 'fingerprint ignores id order, whitespace, duplicates and empty ids');
ok(fpA !== computeDetectFingerprint(['1', '2'], 'full', '重生'), 'fingerprint changes with mode');
ok(fpA !== computeDetectFingerprint(['1', '2'], 'probe', '剑来'), 'fingerprint changes with keyword');
ok(computeDetectFingerprint(['a|b', 'c'], 'probe', 'x') !==
  computeDetectFingerprint(['a', 'b|c'], 'probe', 'x'), 'fingerprint encoding is boundary-safe');
eq(computeDetectFingerprint(['1'], 'unknown', ''), computeDetectFingerprint(['1'], 'full', ''),
  'unknown mode falls back to full');
ok(matchesDetectFingerprint(fpA, ['1', '2'], 'probe', '重生'), 'matching fingerprint accepted');
ok(!matchesDetectFingerprint('', ['1', '2'], 'probe', '重生'), 'empty stored fingerprint rejected');

const empty = newDetectJobState();
const spec = new DetectJobSpec([' 2 ', '1', '10', '2'], 'probe', '重生', 2);
const started = startDetectJob(empty, spec, 1000);
ok(started.accepted, 'start accepted from idle');
eq(started.state.status, 'running', 'start enters running');
eq(started.state.total, 3, 'start stores canonical source count');
eq(started.state.sourceIds.join(','), '1,10,2', 'source ids are sorted deterministically');
eq(nextDetectBatch(started.state).join(','), '1,10', 'first batch follows canonical order');
eq(empty.status, 'idle', 'transition does not mutate idle input');

const runningAgain = startDetectJob(started.state, spec, 1100);
ok(!runningAgain.accepted, 'start while running rejected');
eq(runningAgain.reason, DETECT_TRANSITION_ALREADY_RUNNING, 'running rejection reason');
ok(runningAgain.state === started.state, 'running rejection returns original state');

const badCount = completeDetectBatch(started.state, 3, 1200);
ok(!badCount.accepted, 'batch larger than batchSize rejected');
eq(badCount.reason, DETECT_TRANSITION_BAD_COUNT, 'bad count rejection reason');

const batchOne = completeDetectBatch(started.state, 2, 1300);
ok(batchOne.accepted, 'first batch completes');
eq(batchOne.state.done, 2, 'done advances by processed count');
eq(batchOne.state.cursor, 2, 'cursor advances by processed count');
eq(batchOne.state.status, 'running', 'partial batch remains running');
eq(started.state.cursor, 0, 'batch transition does not mutate prior state');

const cancelled = cancelDetectJob(batchOne.state, 1400);
ok(cancelled.accepted, 'cancel accepted while running');
eq(cancelled.state.status, 'cancelled', 'cancel enters cancelled');
eq(cancelled.state.cursor, 2, 'cancel preserves cursor');
eq(nextDetectBatch(cancelled.state).length, 0, 'cancelled job dispatches no batch');

const resumed = resumeDetectJob(cancelled.state, 1500);
ok(resumed.accepted, 'cancelled job can resume');
eq(resumed.state.status, 'running', 'resume enters running');
eq(resumed.state.cursor, 2, 'resume keeps cursor');
eq(nextDetectBatch(resumed.state).join(','), '2', 'resume dispatches remaining ids');
const finished = completeDetectBatch(resumed.state, 1, 1600);
eq(finished.state.status, 'done', 'last batch enters done');
eq(finished.state.done, 3, 'done count reaches total');
eq(finished.state.cursor, 3, 'cursor reaches total');

const restartedDone = startDetectJob(finished.state, spec, 1700);
ok(restartedDone.accepted, 'done job can start a new round');
eq(restartedDone.state.status, 'running', 'done restart enters running');
eq(restartedDone.state.cursor, 0, 'done restart begins at zero');
eq(restartedDone.state.done, 0, 'done restart clears done count');

const failedJob = failDetectJob(batchOne.state, 'disk full', 1800);
ok(failedJob.accepted, 'failure accepted while running');
eq(failedJob.state.status, 'failed', 'failure enters failed');
eq(failedJob.state.message, 'disk full', 'failure stores detail');
const retried = startDetectJob(failedJob.state, spec, 1900);
ok(retried.accepted, 'failed job can retry with same fingerprint');
eq(retried.state.status, 'running', 'retry enters running');
eq(retried.state.cursor, 2, 'retry keeps original cursor');
eq(retried.state.message, '', 'retry clears failure detail');

const changed = startDetectJob(cancelled.state,
  new DetectJobSpec(['1', '10', '2', '3'], 'probe', '重生', 2), 2000);
ok(changed.accepted, 'changed fingerprint starts a new round');
eq(changed.state.cursor, 0, 'changed fingerprint resets cursor');
eq(changed.state.total, 4, 'changed fingerprint uses current ids');

const emptyStart = startDetectJob(empty, new DetectJobSpec([' ', ''], 'probe', '', 2), 2100);
ok(!emptyStart.accepted, 'empty source set rejected');
eq(emptyStart.reason, DETECT_TRANSITION_EMPTY, 'empty rejection reason');
const illegalResume = resumeDetectJob(empty, 2200);
ok(!illegalResume.accepted, 'idle cannot resume');
eq(illegalResume.reason, DETECT_TRANSITION_NOT_RESUMABLE, 'idle resume rejection reason');

// Engine order is not trusted; canonical ids are restored in batch/cursor order.
const identities = [
  new DetectSourceIdentity(11, 'https://a.example', '甲'),
  new DetectSourceIdentity(12, 'https://b.example', '乙'),
  new DetectSourceIdentity(13, 'https://c.example', '丙')
];
const outOfOrderVerdicts = [
  new DetectEngineVerdict('https://c.example', '丙', false, 'no_results', '', 0, 431),
  new DetectEngineVerdict('https://a.example', '甲', true, 'search', '', 0, 12),
  new DetectEngineVerdict('https://b.example', '乙', false, 'timeout', '超过 8s', 0, 8000)
];
const mappedOutOfOrder = mapDetectBatchResults(identities, outOfOrderVerdicts);
eq(mappedOutOfOrder.error, '', 'out-of-order verdicts map without error');
eq(mappedOutOfOrder.results.map((item: DetectStoredResult) => item.sourceId).join(','), '11,12,13',
  'mapped results follow canonical batch order');
eq(mappedOutOfOrder.results[2].stage, 'no_results', 'mapped verdict keeps its own result');
ok(mapDetectBatchResults(identities, outOfOrderVerdicts.slice(1)).error.length > 0,
  'mapped result count mismatch is rejected');
const unknownVerdict = outOfOrderVerdicts.slice();
unknownVerdict[0] = new DetectEngineVerdict('https://unknown.example', '未知', true, 'search', '', 0, 1);
ok(mapDetectBatchResults(identities, unknownVerdict).error.indexOf('unknown source') >= 0,
  'unknown mapped source is rejected');
const duplicateVerdict = outOfOrderVerdicts.slice();
duplicateVerdict[0] = duplicateVerdict[1];
ok(mapDetectBatchResults(identities, duplicateVerdict).error.indexOf('duplicate detect verdict') >= 0,
  'duplicate mapped verdict is rejected');

// Source-store state mapping is shared by the runner and detect UI.
eq(detectSourceState(true, 'search'), 'ok', 'success maps to ok');
eq(detectSourceState(false, 'no_results'), 'noResult', 'probe miss stays distinct');
eq(detectSourceState(false, 'timeout'), 'timeout', 'timeout stays distinct');
eq(detectSourceState(false, 'toc_fetch'), 'unavailable', 'hard failure maps to unavailable');

// job.json stores only the frozen trace contract, never runtime source ids.
const diskRaw = encodeDetectJobState(batchOne.state);
ok(diskRaw.indexOf('sourceIds') < 0, 'job.json excludes runtime sourceIds');
const diskState = decodeDetectJobState(diskRaw);
ok(diskState !== undefined, 'valid job.json decodes');
if (diskState !== undefined) {
  eq(diskState.status, 'running', 'job.json keeps status');
  eq(diskState.cursor, 2, 'job.json keeps cursor');
  eq(diskState.fingerprint, batchOne.state.fingerprint, 'job.json keeps fingerprint');
  eq(diskState.sourceIds.length, 0, 'decoded job.json has no runtime ids');
}
eq(decodeDetectJobState('{"status":"running"'), undefined, 'partial job.json is rejected');
eq(decodeDetectJobState('{"status":"running","mode":"probe","keyword":"","total":3,"done":1,"cursor":2,' +
  '"batchSize":32,"startedAt":1,"updatedAt":2,"fingerprint":"x","message":""}'), undefined,
  'inconsistent done/cursor is rejected');
eq(decodeDetectJobState('{"status":"running","mode":"probe","keyword":"","total":3,"done":3,"cursor":3,' +
  '"batchSize":32,"startedAt":1,"updatedAt":2,"fingerprint":"x","message":""}'), undefined,
  'running job with an exhausted cursor is rejected');
eq(decodeDetectJobState('{"status":"done","mode":"probe","keyword":"","total":3,"done":2,"cursor":2,' +
  '"batchSize":32,"startedAt":1,"updatedAt":2,"fingerprint":"x","message":""}'), undefined,
  'done job before the canonical end is rejected');

const reconciledAhead = reconcileDetectCursor(started.state, 2, 2300);
ok(reconciledAhead.accepted, 'recovery can advance stale job.json cursor');
eq(reconciledAhead.state.done, 2, 'recovery advances done with cursor');
eq(reconciledAhead.state.cursor, 2, 'recovery advances cursor');
const reconciledDone = reconcileDetectCursor(started.state, 3, 2400);
eq(reconciledDone.state.status, 'done', 'recovery completes a job whose results reached total');
const reconciledBack = reconcileDetectCursor(batchOne.state, 0, 2500);
eq(reconciledBack.state.cursor, 0, 'recovery rewinds past a corrupt result tail');
eq(reconciledBack.state.done, 0, 'recovery rewinds done with cursor');
ok(!reconcileDetectCursor(cancelled.state, 3, 2600).accepted, 'recovery rejects non-running jobs');

// JSONL is append-only. A crash may truncate only the final record.
const lineA = new DetectBatchLine(0, 1, 100, [
  new DetectStoredResult(11, 'https://a.example', '甲', true, 'search', '', 0, 12)
]);
const lineB = new DetectBatchLine(1, 3, 200, [
  new DetectStoredResult(12, 'https://b.example', '乙', false, 'timeout', '超过 8s', 0, 8000),
  new DetectStoredResult(13, 'https://c.example', '丙', false, 'no_results', '', 0, 431)
]);
const lineC = new DetectBatchLine(3, 5, 300, [
  new DetectStoredResult(14, 'https://d.example', '丁', true, 'search', '', 0, 25),
  new DetectStoredResult(15, 'https://e.example', '戊', false, 'network_error', '连接失败', 0, 81)
]);
const goodRaw = encodeDetectBatchLine(lineA) + encodeDetectBatchLine(lineB);
const goodJsonl = recoverDetectJsonl(goodRaw);
eq(goodJsonl.lines.length, 2, 'complete JSONL lines are recovered');
eq(goodJsonl.contiguousCursor, 3, 'JSONL recovery reports the contiguous cursor');
eq(goodJsonl.invalidLines, 0, 'complete JSONL has no invalid lines');
ok(!goodJsonl.unterminated, 'newline-terminated JSONL is not marked unterminated');
ok(!goodJsonl.discontinuity, 'contiguous JSONL has no gap');
eq(goodJsonl.lines[1].results[1].sourceName, '丙', 'JSONL keeps unicode result fields');
ok(detectJsonlCanContinue(goodJsonl), 'contiguous JSONL is continuable');
const replayIds = ['11', '12', '13'];
const replayAll = replayDetectResultsForJob(goodJsonl.lines, 0, 3, replayIds);
ok(replayAll !== undefined, 'complete JSONL replays for its canonical ids');
if (replayAll !== undefined) {
  eq(replayAll.map((item: DetectStoredResult) => item.sourceId).join(','), '11,12,13',
    'JSONL replay preserves canonical result order');
}
const replayStale = replayDetectResultsForJob(goodJsonl.lines, 1, 3, replayIds);
ok(replayStale !== undefined, 'stale cursor replays only the remaining batches');
if (replayStale !== undefined) {
  eq(replayStale.map((item: DetectStoredResult) => item.sourceId).join(','), '12,13',
    'stale cursor does not replay already committed ids twice');
}
const replayBatches = replayDetectBatchLinesForJob(goodJsonl.lines, 1, 3, replayIds);
ok(replayBatches !== undefined, 'stale cursor replays complete batches');
if (replayBatches !== undefined) {
  eq(replayBatches.length, 1, 'stale cursor keeps the remaining batch boundary');
  eq(replayBatches[0].at, 200, 'batch replay preserves its original append timestamp');
  eq(replayBatches[0].results.map((item: DetectStoredResult) => item.sourceId).join(','), '12,13',
    'batch replay keeps canonical results in order');
}
eq(replayDetectBatchLinesForJob(goodJsonl.lines, 0, 3, ['11', '99', '13']), undefined,
  'batch replay validates result ids against the frozen job');
eq(replayDetectResultsForJob(goodJsonl.lines, 0, 3, ['11', '99', '13']), undefined,
  'JSONL replay rejects a result at the wrong canonical id');
eq(replayDetectResultsForJob(goodJsonl.lines, 0, 4, replayIds), undefined,
  'JSONL replay rejects a cursor beyond the frozen source ids');

const noNewline = goodRaw.slice(0, -1);
const noNewlineJsonl = recoverDetectJsonl(noNewline);
eq(noNewlineJsonl.lines.length, 2, 'complete final JSON without newline is retained');
ok(noNewlineJsonl.unterminated, 'missing final newline is detected');
eq(detectJsonlSeparator(noNewline), '\n', 'missing newline gets an append separator');
eq(detectJsonlSeparator(goodRaw), '', 'terminated JSONL needs no separator');

const partialRaw = goodRaw + '{"cursor":3,"nextCursor":5,"at":300,"results":[{"sourceId":';
const partialJsonl = recoverDetectJsonl(partialRaw);
eq(partialJsonl.lines.length, 2, 'partial final line does not hide completed batches');
eq(partialJsonl.invalidLines, 1, 'partial final line is reported invalid');
eq(partialJsonl.contiguousCursor, 3, 'partial final line does not advance cursor');
ok(partialJsonl.unterminated, 'partial final line is unterminated');
const repairedRaw = partialRaw + detectJsonlSeparator(partialRaw) + encodeDetectBatchLine(lineC);
const repairedJsonl = recoverDetectJsonl(repairedRaw);
eq(repairedJsonl.lines.length, 3, 'append after partial tail remains readable');
eq(repairedJsonl.contiguousCursor, 5, 'append after partial tail reaches the next cursor');
eq(repairedJsonl.lines[2].results[0].sourceId, 14, 'append after partial tail keeps the new batch');
ok(detectJsonlCanContinue(repairedJsonl), 'partial tail followed by a valid append can continue');

const gapRaw = encodeDetectBatchLine(lineA) + '{broken}\n' + encodeDetectBatchLine(lineC);
const gapJsonl = recoverDetectJsonl(gapRaw);
eq(gapJsonl.lines.length, 2, 'malformed middle line is skipped');
eq(gapJsonl.invalidLines, 1, 'malformed middle line is counted');
eq(gapJsonl.contiguousCursor, 1, 'gap stops contiguous cursor at the last complete batch');
ok(gapJsonl.discontinuity, 'malformed middle line marks a discontinuity');
ok(!detectJsonlCanContinue(gapJsonl), 'gap cannot be continued');

const duplicateJsonl = recoverDetectJsonl(
  encodeDetectBatchLine(lineA) + encodeDetectBatchLine(lineA) + encodeDetectBatchLine(lineB));
eq(duplicateJsonl.contiguousCursor, 3, 'duplicate replayed batch does not advance twice');
ok(!duplicateJsonl.discontinuity, 'duplicate replayed batch is not a gap');

const wrongCountRaw = '{"cursor":0,"nextCursor":2,"at":1,"results":[' +
  JSON.stringify(lineA.results[0]) + ']}\n';
eq(recoverDetectJsonl(wrongCountRaw).invalidLines, 1, 'result count must match cursor span');

const duplicateIdsRaw = '{"cursor":0,"nextCursor":2,"at":1,"results":[' +
  JSON.stringify(lineA.results[0]) + ',' + JSON.stringify(lineA.results[0]) + ']}\n';
eq(recoverDetectJsonl(duplicateIdsRaw).invalidLines, 1, 'duplicate source ids within a batch are invalid');

const staleNames = ['results-900.jsonl', 'notes.txt', 'results-700.jsonl', 'results-800.jsonl'];
const staleFiles = detectResultFilesToDelete(staleNames, 1000);
eq(staleFiles.length, 2, 'result retention removes all but the current and newest previous round');
eq(staleFiles.indexOf('results-900.jsonl'), -1, 'result retention keeps the newest previous round');
eq(staleFiles.indexOf('results-800.jsonl') >= 0, true, 'result retention removes older rounds');
eq(staleFiles.indexOf('results-700.jsonl') >= 0, true, 'result retention removes the oldest round');
eq(staleFiles.indexOf('notes.txt'), -1, 'result retention leaves unrelated files alone');

if (failures.length > 0) {
  console.log('FAILED ' + failures.length + ' / ' + (passed + failures.length));
  for (const item of failures) { console.log('  ' + item); }
  process.exitCode = 1;
} else {
  console.log('PASS ' + passed + ' detect-job contract assertions');
}
"""


def read(rel):
    with open(os.path.join(ROOT, rel), encoding='utf-8') as f:
        return f.read()


def strip_imports(text):
    return '\n'.join(line for line in text.splitlines() if not line.startswith('import '))


def main():
    const = read('entry/src/main/ets/common/Const.ets')
    batch_line = next((line for line in const.splitlines()
                       if line.startswith('export const DETECT_BATCH_SIZE:')), None)
    if batch_line is None:
        sys.exit('slice failed: DETECT_BATCH_SIZE not found in common/Const.ets')

    job = strip_imports(read('entry/src/main/ets/model/DetectJob.ets'))
    for needle in ('export function startDetectJob', 'export function computeDetectFingerprint',
                   'export function recoverDetectJsonl',
                   'export const DETECT_JOB_TRACE_FIELDS'):
        if needle not in job:
            sys.exit('slice failed: %r missing from model/DetectJob.ets' % needle)
    if '@kit.' in job or '@ohos.' in job:
        sys.exit('purity failed: DetectJob.ets imports a HarmonyOS kit module')

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(WORK, 'detect-job.ts')
    with open(src, 'w', encoding='utf-8') as f:
        f.write(batch_line.replace('export const ', 'const ', 1) + '\n')
        f.write(job + '\n' + TEST + '\n')

    tsc = next((path for path in TSC_CANDIDATES if os.path.exists(path)), None)
    if tsc is None:
        sys.exit('DevEco tsc not found; update TSC_CANDIDATES')
    out = os.path.join(WORK, 'out')
    proc = subprocess.run([tsc, '--target', 'es2020', '--module', 'commonjs', '--lib', 'es2020',
                           '--strict', '--outDir', out, src], capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout + proc.stderr)
        sys.exit('tsc failed')
    return subprocess.call(['node', os.path.join(out, 'detect-job.js')])


if __name__ == '__main__':
    sys.exit(main())

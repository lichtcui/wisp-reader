import { Chapter } from '../engine/types';

/** Volume entries (`isVolume`) are section headers, not readable chapters. */
export function isReadable(chapters: Chapter[], index: number): boolean {
  return index >= 0 && index < chapters.length && chapters[index].isVolume !== true;
}

export function firstReadable(chapters: Chapter[]): number {
  for (let i = 0; i < chapters.length; i++) {
    if (isReadable(chapters, i)) {
      return i;
    }
  }
  return -1;
}

export function nextReadable(chapters: Chapter[], from: number): number {
  for (let i = from + 1; i < chapters.length; i++) {
    if (isReadable(chapters, i)) {
      return i;
    }
  }
  return -1;
}

export function prevReadable(chapters: Chapter[], from: number): number {
  for (let i = from - 1; i >= 0; i--) {
    if (isReadable(chapters, i)) {
      return i;
    }
  }
  return -1;
}
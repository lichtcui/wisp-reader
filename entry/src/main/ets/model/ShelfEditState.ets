/**
 * Shelf edit mode (multi-select → delete) shared state.
 *
 * One instance is owned by `Index` and passed to `ShelfPage` through `@Param`
 * (V2 passes objects by reference), so a single `@Trace` write refreshes the
 * top bar, the bottom action bar and the grid/list rows together. All writes go
 * through the methods below — components never mutate `selected` directly.
 *
 * Official V2 rules this class relies on (第四轮已取证):
 * - `@Param` only observes a *whole-object* reassignment; member changes rely on
 *   `@ObservedV2` + `@Trace` (`arkts-new-param.md` §观察变化).
 * - A child component **may** modify the object's properties (our `ShelfPage`
 *   calls `setBooks`), but must **not** reassign the `@Param` variable itself
 *   (`this.edit = …` is a compile error) — never do that.
 * - Every field the UI reads must be `@Trace`, and a `@Trace` write only
 *   refreshes the components that *read* that property.
 * - The instance must be created with `new`; a `JSON.parse` result is not an
 *   instance and loses observability — so never restore this from storage.
 *
 * Release/obfuscation constraint (SHELF-EDIT-PLAN §5.5 K15): members of an
 * `@ObservedV2` **class** are *not* auto-kept by ArkGuard (unlike ArkUI struct
 * members), so never address them by string — no `@Monitor('edit.selected')`,
 * no `this.edit['selected']`, no JSON round-trip.
 */
@ObservedV2
export class ShelfEditState {
  @Trace editing: boolean = false;
  @Trace selected: string[] = [];
  /** Every book id currently on the shelf; reported by ShelfPage after a reload. */
  @Trace bookIds: string[] = [];

  /** Long press: enter edit mode with that book selected. */
  enter(bookId: string): void {
    this.editing = true;
    this.selected = bookId.length > 0 ? [bookId] : [];
  }

  /** Leave edit mode and drop the selection (no side effects on data). */
  exit(): void {
    this.editing = false;
    this.selected = [];
  }

  isSelected(bookId: string): boolean {
    return this.selected.indexOf(bookId) >= 0;
  }

  count(): number {
    return this.selected.length;
  }

  /** True when every book on the shelf is selected (empty shelf → false). */
  allSelected(): boolean {
    if (this.bookIds.length === 0) {
      return false;
    }
    // Iterate the shelf list instead of comparing lengths: that way a stale or
    // duplicated id in `selected` can never make this report a wrong "all".
    for (let i = 0; i < this.bookIds.length; i++) {
      if (!this.isSelected(this.bookIds[i])) {
        return false;
      }
    }
    return true;
  }

  /** Tap in edit mode. */
  toggle(bookId: string): void {
    const next: string[] = this.selected.filter((id: string) => id !== bookId);
    if (next.length === this.selected.length) {
      next.push(bookId);
    }
    this.selected = next;
  }

  /** 全选 / 取消全选. */
  toggleAll(): void {
    this.selected = this.allSelected() ? [] : this.bookIds.slice();
  }

  /**
   * Shelf reload: refresh the selectable set, drop ids that disappeared, and
   * leave edit mode when the shelf became empty. Ids are compared before the
   * write so an unchanged reload does not wake the UI up again.
   */
  setBooks(ids: string[]): void {
    if (!sameIds(this.bookIds, ids)) {
      this.bookIds = ids;
    }
    const kept: string[] = this.selected.filter((id: string) => ids.indexOf(id) >= 0);
    if (kept.length !== this.selected.length) {
      this.selected = kept;
    }
    if (this.editing && ids.length === 0) {
      this.editing = false;
    }
  }
}

function sameIds(a: string[], b: string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}
